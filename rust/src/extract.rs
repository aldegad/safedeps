//! The spec extractor of the guard: a word as its manager reads it
//! (`guard_word_as_read`), the specs one word carries (`guard_word_specs`), the
//! package a create runs (`guard_create_identity`), npm-package-arg's local
//! test (`safedeps_npa_is_local`) and the extractor itself
//! (`guard_extract_specs`, readings mode).
//!
//! The shell reads several of these with `[[ =~ ]]` and BASH_REMATCH. Where a
//! pattern's parts are fixed by its shape (an anchored pattern whose classes
//! leave one way to match), the parts are cut here by hand, beside the
//! pattern they stand for. The one unanchored search, the spec token loop,
//! asks the regex engine for the POSIX leftmost-longest match.

use crate::ere::Regex;
use crate::manager::Reader;

type W = Vec<u8>;

pub struct XRegexes {
    token: Regex,
    email: Regex,
    gem_version: Regex,
    go: Regex,
    npa_url: Regex,
    npa_scp: Regex,
    npa_tarball: Regex,
    npa_hosted: Regex,
}

impl XRegexes {
    pub fn new() -> XRegexes {
        let r = |p: &str| Regex::new(p, false).expect("extractor regex");
        XRegexes {
            // bash 3.2 reads `\<\>` inside the brackets as `<` and `>`, no
            // backslash (measured on the macOS bash the hooks run under).
            token: r("(@[a-zA-Z0-9._/-]+/)?[a-zA-Z0-9][a-zA-Z0-9._-]*@[a-zA-Z0-9._^~|<>=*+-]+"),
            email: r("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"),
            gem_version: r("^[0-9]+([.][0-9A-Za-z]+)*(-[0-9A-Za-z-]+([.][0-9A-Za-z-]+)*)?$"),
            go: r("^[A-Za-z0-9][A-Za-z0-9._~/-]*@[A-Za-z0-9._+~-]+$"),
            npa_url: r(crate::grammar::NPA_URL_RE),
            npa_scp: r(crate::grammar::NPA_SCP_RE),
            npa_tarball: r(crate::grammar::NPA_TARBALL_RE),
            npa_hosted: r(crate::grammar::NPA_HOSTED_RE),
        }
    }
}

pub fn family_ecosystem(f: &str) -> &'static str {
    match f {
        "npm" | "npx" | "pnpm" | "pnpx" | "yarn" | "bun" | "bunx" => "npm",
        "pip" | "uv" | "uvx" | "pipx" | "poetry" | "pipenv" => "pypi",
        "cargo" => "crates.io",
        "go" => "go",
        "gem" | "bundle" => "rubygems",
        "mvn" => "maven",
        "dotnet" => "nuget",
        _ => "",
    }
}

pub fn word_as_read(eco: &str, word: &[u8]) -> W {
    let mut w: W = if eco == "pypi" {
        word.iter().copied().filter(|&b| b != 0x02).collect()
    } else {
        let s = word.iter().position(|&b| b != 0x02).unwrap_or(word.len());
        let e = word.iter().rposition(|&b| b != 0x02).map(|p| p + 1).unwrap_or(s);
        word[s..e.max(s)].to_vec()
    };
    if w.is_empty() {
        w = vec![0x02];
    }
    w
}

/// `\[[^] ]*\]` removed, first match first, until none is left.
fn strip_extras(word: &[u8]) -> W {
    let mut w = word.to_vec();
    loop {
        let mut found = None;
        for i in 0..w.len() {
            if w[i] != b'[' {
                continue;
            }
            let mut j = i + 1;
            while j < w.len() && w[j] != b']' && w[j] != b' ' {
                j += 1;
            }
            if j < w.len() && w[j] == b']' {
                found = Some((i, j + 1));
                break;
            }
        }
        match found {
            Some((a, b)) => {
                w.drain(a..b);
            }
            None => return w,
        }
    }
}

fn cls_npm_name(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'~' | b'-')
}

/// `^(@[A-Za-z0-9._~-]+/)?[A-Za-z0-9._~-]+@[Nn][Pp][Mm]:(.*)$`: the target
/// of an npm alias. `nonempty` for `(.+)`.
fn npm_alias_target(w: &[u8], nonempty: bool) -> Option<W> {
    let mut p = 0;
    if w.first() == Some(&b'@') {
        let mut q = 1;
        while q < w.len() && cls_npm_name(w[q]) {
            q += 1;
        }
        if q == 1 || q >= w.len() || w[q] != b'/' {
            return None;
        }
        p = q + 1;
    }
    let s = p;
    while p < w.len() && cls_npm_name(w[p]) {
        p += 1;
    }
    if p == s || p + 5 > w.len() || w[p] != b'@' || !w[p + 1..p + 4].eq_ignore_ascii_case(b"npm") || w[p + 4] != b':' {
        return None;
    }
    let rest = &w[p + 5..];
    if nonempty && rest.is_empty() {
        return None;
    }
    Some(rest.to_vec())
}

fn is_name_word(w: &[u8]) -> bool {
    !w.is_empty() && w[0].is_ascii_alphanumeric() && w[1..].iter().all(|&b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn rsplit_at(w: &[u8]) -> (W, W) {
    match w.iter().rposition(|&b| b == b'@') {
        Some(p) => (w[..p].to_vec(), w[p + 1..].to_vec()),
        None => (w.to_vec(), w.to_vec()),
    }
}

pub fn word_specs(x: &XRegexes, eco: &str, word: &[u8]) -> Vec<(W, W)> {
    let mut out = Vec::new();
    let mut word = word.to_vec();
    if eco == "go" {
        if x.go.is_match(&word) {
            out.push(rsplit_at(&word));
        }
        return out;
    }
    if eco == "pypi" {
        word = strip_extras(&word);
        if let Some(e) = word.iter().position(|&b| b == b'=') {
            let name = &word[..e];
            let mut q = e;
            while q < word.len() && word[q] == b'=' {
                q += 1;
            }
            let eqs = q - e;
            let ver = &word[q..];
            if is_name_word(name)
                && (eqs == 2 || eqs == 3)
                && !ver.is_empty()
                && ver[0].is_ascii_alphanumeric()
                && ver[1..].iter().all(|&b| b.is_ascii_alphanumeric() || b"._+!~-".contains(&b))
            {
                out.push((name.to_vec(), ver.to_vec()));
                return out;
            }
        }
    }
    if eco == "rubygems" {
        if let Some(c) = word.iter().position(|&b| b == b':') {
            let name = &word[..c];
            let mut ver = &word[c + 1..];
            if ver.first() == Some(&b'=') {
                ver = &ver[1..];
            }
            if is_name_word(name) && x.gem_version.is_match(ver) {
                out.push((name.to_vec(), ver.to_vec()));
                return out;
            }
        }
    }
    if eco == "npm" {
        if let Some(t) = npm_alias_target(&word, false) {
            word = t;
        }
    }
    let mut rest = word;
    while let Some((s, e)) = x.token.find(&rest) {
        let token = rest[s..e].to_vec();
        // `rest="${rest#*"${token}"}"`: past the first place the token is.
        let at = rest.windows(token.len()).position(|w| w == token.as_slice()).unwrap_or(s);
        rest = rest[at + token.len()..].to_vec();
        if x.email.is_match(&token) {
            continue;
        }
        // `^(@[^@]+)@(.+)$`
        if token.first() == Some(&b'@') {
            if let Some(q) = token[1..].iter().position(|&b| b == b'@').map(|p| p + 1) {
                if q > 1 && q + 1 < token.len() {
                    out.push((token[..q].to_vec(), token[q + 1..].to_vec()));
                    continue;
                }
            }
        }
        out.push(rsplit_at(&token));
    }
    out
}

pub fn create_identity(family: &str, spec: &[u8]) -> Vec<W> {
    let mut out = Vec::new();
    if family == "bun" {
        match spec {
            b"react" | b"next" => return out,
            b"elysia" | b"elysia-buchta" | b"stric" => {
                let mut v = b"@bun-examples/".to_vec();
                v.extend_from_slice(spec);
                out.push(v);
                return out;
            }
            _ => {}
        }
    }
    if matches!(spec.first(), Some(b'.') | Some(b'/') | Some(b'~')) {
        return out;
    }
    if spec.windows(3).any(|w| w == b"://") {
        out.push(spec.to_vec());
        return out;
    }
    // ^(@[^/@]+)(@.*)?$
    if spec.first() == Some(&b'@') {
        let mut q = 1;
        while q < spec.len() && spec[q] != b'/' && spec[q] != b'@' {
            q += 1;
        }
        if q > 1 && (q == spec.len() || spec[q] == b'@') {
            let mut v = spec[..q].to_vec();
            v.extend_from_slice(b"/create");
            v.extend_from_slice(&spec[q..]);
            out.push(v);
            return out;
        }
    }
    // ^(@[^/@]+/)?([^/@]+)(@.*)?$
    {
        let mut p = 0;
        let mut ok = true;
        if spec.first() == Some(&b'@') {
            let mut q = 1;
            while q < spec.len() && spec[q] != b'/' && spec[q] != b'@' {
                q += 1;
            }
            if q > 1 && q < spec.len() && spec[q] == b'/' {
                p = q + 1;
            } else {
                ok = false;
            }
        }
        if ok {
            let s = p;
            while p < spec.len() && spec[p] != b'/' && spec[p] != b'@' {
                p += 1;
            }
            if p > s && (p == spec.len() || spec[p] == b'@') {
                let scope = spec[..s].to_vec();
                let mut name = spec[s..p].to_vec();
                let version = spec[p..].to_vec();
                let cat = |sc: &[u8], n: &[u8], v: &[u8]| -> W {
                    let mut r = sc.to_vec();
                    r.extend_from_slice(n);
                    r.extend_from_slice(v);
                    r
                };
                match family {
                    "pnpm" => {
                        if !name.starts_with(b"create-") {
                            let mut n = b"create-".to_vec();
                            n.extend_from_slice(&name);
                            name = n;
                        }
                    }
                    "yarn" => {
                        if name.starts_with(b"create") && (name.len() == 6 || name[6] == b'-') {
                            out.push(cat(&scope, &name, &version));
                        }
                        let mut n = b"create-".to_vec();
                        n.extend_from_slice(&name);
                        name = n;
                    }
                    _ => {
                        let mut n = b"create-".to_vec();
                        n.extend_from_slice(&name);
                        name = n;
                    }
                }
                out.push(cat(&scope, &name, &version));
                return out;
            }
        }
    }
    // ^((github|gitlab|bitbucket|gist):)?([^/:@]+)/([^/#:]+)(#.*)?$
    if family == "npm" {
        let mut pre: &[u8] = b"";
        for h in [&b"github:"[..], b"gitlab:", b"bitbucket:", b"gist:"] {
            if spec.starts_with(h) {
                pre = h;
                break;
            }
        }
        let r = &spec[pre.len()..];
        let mut p = 0;
        while p < r.len() && !matches!(r[p], b'/' | b':' | b'@') {
            p += 1;
        }
        if p > 0 && p < r.len() && r[p] == b'/' {
            let s = p + 1;
            let mut q = s;
            while q < r.len() && !matches!(r[q], b'/' | b'#' | b':') {
                q += 1;
            }
            if q > s && (q == r.len() || r[q] == b'#') {
                let mut v = pre.to_vec();
                v.extend_from_slice(&r[..p]);
                v.extend_from_slice(b"/create-");
                v.extend_from_slice(&r[s..q]);
                v.extend_from_slice(&r[q..]);
                out.push(v);
                return out;
            }
        }
    }
    out.push(spec.to_vec());
    out
}

fn npa_spec_is_local(x: &XRegexes, spec: &[u8]) -> bool {
    if spec.is_empty() {
        return false;
    }
    if spec.len() >= 5 && spec[..5].eq_ignore_ascii_case(b"file:") {
        return true;
    }
    if matches!(spec[0], b'.' | b'/') || spec.starts_with(b"~/") || (spec.len() >= 2 && spec[0].is_ascii_alphabetic() && spec[1] == b':') {
        return true;
    }
    if spec.len() >= 4 && spec[..4].eq_ignore_ascii_case(b"npm:") {
        return false;
    }
    if x.npa_url.is_match(spec) || x.npa_hosted.is_match(spec) {
        return false;
    }
    spec.contains(&b'/') || x.npa_tarball.is_match(spec)
}

pub fn npa_is_local(x: &XRegexes, arg: &[u8]) -> bool {
    if (arg.len() >= 5 && arg[..5].eq_ignore_ascii_case(b"file:"))
        || matches!(arg.first(), Some(b'.') | Some(b'/'))
        || arg.starts_with(b"~/")
        || (arg.len() >= 2 && arg[0].is_ascii_alphabetic() && arg[1] == b':')
    {
        return true;
    }
    if x.npa_url.is_match(arg) || x.npa_scp.is_match(arg) {
        return false;
    }
    let (namepart, spec): (W, W);
    if arg.first() == Some(&b'@') {
        let rest = &arg[1..];
        if let Some(p) = rest.iter().position(|&b| b == b'@') {
            let mut np = vec![b'@'];
            np.extend_from_slice(&rest[..p]);
            namepart = np;
            spec = rest[p + 1..].to_vec();
        } else {
            namepart = arg.to_vec();
            spec = W::new();
        }
    } else if let Some(p) = arg.iter().position(|&b| b == b'@').filter(|&p| p >= 1) {
        namepart = arg[..p].to_vec();
        spec = arg[p + 1..].to_vec();
    } else {
        namepart = arg.to_vec();
        spec = W::new();
    }
    if namepart.first() != Some(&b'@') && (namepart.contains(&b'/') || x.npa_tarball.is_match(&namepart)) {
        return npa_spec_is_local(x, arg);
    }
    if namepart == arg {
        return false;
    }
    npa_spec_is_local(x, &spec)
}

/// `-Dartifact=([^:]+):([^:]+):([^:]+)`, unanchored at the end.
fn maven_coordinate(t: &[u8]) -> Option<(W, W, W)> {
    let p = t.strip_prefix(b"-Dartifact=")?;
    let mut parts = Vec::new();
    let mut s = 0;
    for _ in 0..3 {
        let mut e = s;
        while e < p.len() && p[e] != b':' {
            e += 1;
        }
        if e == s {
            return None;
        }
        parts.push(p[s..e].to_vec());
        if parts.len() < 3 {
            if e >= p.len() {
                return None;
            }
            s = e + 1;
        }
    }
    Some((parts[0].clone(), parts[1].clone(), parts[2].clone()))
}

/// One statement of the extractor: the words after the shell's quote
/// removal (the pieces view, `\002` inside a word), whether the effect gate
/// reads it, and the reading of its manager. The lines it prints, in
/// readings mode.
pub fn extract_statement(x: &XRegexes, rd: &mut Reader, gate_reads: bool, words: &[u8], out: &mut W) {
    let words: W = words.iter().map(|&b| if matches!(b, b'(' | b')' | b'{' | b'}') { b' ' } else { b }).collect();
    let w: Vec<W> = words
        .split(|&b| b == b' ' || b == b'\t' || b == b'\n')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_vec())
        .collect();
    if w.is_empty() {
        return;
    }
    rd.read(&w);
    if rd.kind == "none" {
        return;
    }
    let family = rd.family.clone();
    let eco = family_ecosystem(&family);
    if eco.is_empty() {
        return;
    }
    let roles = rd.role.clone();
    let texts = rd.text.clone();
    let mut o: W = Vec::new();
    o.extend_from_slice(format!("S\t{}\t{}\t{}\n", eco, rd.localbin, gate_reads).as_bytes());
    let word_of = |k: usize| -> W {
        match texts.get(k) {
            Some(t) if !t.is_empty() => t.clone(),
            _ => w[k].clone(),
        }
    };
    let mut versions: Vec<W> = Vec::new();
    for k in 0..w.len() {
        if roles.get(k) == Some(&b'V') {
            versions.push(word_as_read(eco, &word_of(k)));
        }
    }
    let line = |o: &mut W, parts: &[&[u8]]| {
        for (i, p) in parts.iter().enumerate() {
            if i > 0 {
                o.push(b'\t');
            }
            o.extend_from_slice(p);
        }
        o.push(b'\n');
    };
    for k in 0..w.len() {
        let role = roles.get(k).copied().unwrap_or(b'-');
        if !b"orCpwD".contains(&role) {
            continue;
        }
        let mut text = word_as_read(eco, &word_of(k));
        if eco == "pypi" {
            text = strip_extras(&text);
        } else if eco == "npm" {
            if let Some(t) = npm_alias_target(&text, true) {
                text = t;
            }
        }
        if rd.kind == "link" && npa_is_local(x, &text) {
            continue;
        }
        let ks = k.to_string();
        if role == b'D' {
            let mut t = b"-D".to_vec();
            t.extend_from_slice(&text);
            if let Some((g, a, v)) = maven_coordinate(&t) {
                let mut ga = g.clone();
                ga.push(b':');
                ga.extend_from_slice(&a);
                line(&mut o, &[eco.as_bytes(), &ga, &v]);
                line(&mut o, &[b"@", b"bound", ks.as_bytes()]);
            }
            line(&mut o, &[b"O", ks.as_bytes(), b"D", &t]);
            continue;
        }
        if role == b'C' {
            let fam = match family.as_str() {
                "npm" | "npx" => "npm",
                "pnpm" | "pnpx" => "pnpm",
                "bun" | "bunx" => "bun",
                f => f,
            };
            for created in create_identity(fam, &text) {
                if created.is_empty() {
                    continue;
                }
                for (pkg, spec) in word_specs(x, eco, &created) {
                    line(&mut o, &[eco.as_bytes(), &pkg, &spec]);
                    line(&mut o, &[b"@", b"bound", ks.as_bytes()]);
                }
                line(&mut o, &[b"O", ks.as_bytes(), b"r", &created]);
            }
            continue;
        }
        for (pkg, spec) in word_specs(x, eco, &text) {
            line(&mut o, &[eco.as_bytes(), &pkg, &spec]);
            line(&mut o, &[b"@", b"bound", ks.as_bytes()]);
        }
        if role == b'o' {
            for v in &versions {
                if v.is_empty() {
                    continue;
                }
                line(&mut o, &[eco.as_bytes(), &text, v]);
                line(&mut o, &[b"@", b"bound", ks.as_bytes()]);
            }
        }
        line(&mut o, &[b"O", ks.as_bytes(), &[role], &text]);
    }
    out.extend_from_slice(&o);
}
