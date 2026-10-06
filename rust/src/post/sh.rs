//! What the bash post hook gets from the shell and from the small commands it
//! runs, done in this process: the file tests, `cp`, `rm -rf`, `cmp`,
//! `mktemp`, a `read` with a tab for IFS, and a glob match. Each says in its
//! comment which behaviour of the command it keeps, because the hook's lines
//! state what these returned (`cp exit 1`, `rm exit 1`).

use std::io::{Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

extern "C" {
    fn access(path: *const std::os::raw::c_char, mode: i32) -> i32;
}

pub fn p(b: &[u8]) -> PathBuf {
    PathBuf::from(std::ffi::OsStr::from_bytes(b))
}

pub fn bytes(path: &Path) -> &[u8] {
    path.as_os_str().as_bytes()
}

/// `[[ -e p ]]`: what the path names exists, a link followed.
pub fn exists(path: &Path) -> bool {
    std::fs::metadata(path).is_ok()
}

/// `[[ -L p ]]`
pub fn is_link(path: &Path) -> bool {
    std::fs::symlink_metadata(path).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

/// `[[ -e p || -L p ]]`
pub fn present(path: &Path) -> bool {
    std::fs::symlink_metadata(path).is_ok()
}

/// `[[ -f p ]]`: a regular file, a link followed.
pub fn is_file(path: &Path) -> bool {
    std::fs::metadata(path).map(|m| m.is_file()).unwrap_or(false)
}

/// `[[ -d p ]]`: a directory, a link followed.
pub fn is_dir(path: &Path) -> bool {
    std::fs::metadata(path).map(|m| m.is_dir()).unwrap_or(false)
}

/// `[[ -r p ]]`
pub fn readable(path: &Path) -> bool {
    let Ok(c) = std::ffi::CString::new(bytes(path)) else { return false };
    unsafe { access(c.as_ptr(), 4) == 0 }
}

pub fn command_exists(name: &str) -> bool {
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).any(|dir| {
        let path=dir.join(name);
        let Ok(c)=std::ffi::CString::new(bytes(&path)) else{return false};
        is_file(&path) && unsafe{access(c.as_ptr(),1)==0}
    })
}

/// Whether the hook's locale reads text as UTF-8, as bash decides it for `?`
/// in a pattern: LC_ALL, then LC_CTYPE, then LANG.
pub fn utf8_locale() -> bool {
    let loc = ["LC_ALL", "LC_CTYPE", "LANG"]
        .iter()
        .filter_map(|k| std::env::var(k).ok())
        .find(|v| !v.is_empty())
        .unwrap_or_default()
        .to_ascii_lowercase();
    loc.contains("utf-8") || loc.contains("utf8")
}

/// `IFS=$'\t' read -r a b ... <<< line` with `n` names. A tab is IFS
/// whitespace: tabs in front are dropped, a run of them is one separator, and
/// the last name takes the rest without the tabs that end it.
pub fn read_tab(line: &[u8], n: usize) -> Vec<Vec<u8>> {
    let mut out: Vec<Vec<u8>> = Vec::with_capacity(n);
    let mut i = 0;
    while i < line.len() && line[i] == b'\t' {
        i += 1;
    }
    while out.len() + 1 < n {
        let st = i;
        while i < line.len() && line[i] != b'\t' {
            i += 1;
        }
        out.push(line[st..i].to_vec());
        while i < line.len() && line[i] == b'\t' {
            i += 1;
        }
    }
    let mut end = line.len();
    while end > i && line[end - 1] == b'\t' {
        end -= 1;
    }
    out.push(line[i..end].to_vec());
    out
}

/// `cut -f<n>` of a line (1-based): the line itself when it has no tab.
pub fn cut_field(line: &[u8], n: usize) -> &[u8] {
    if !line.contains(&b'\t') {
        return line;
    }
    line.split(|&b| b == b'\t').nth(n - 1).unwrap_or(b"")
}

/// `cut -f<n>-` of a line.
pub fn cut_from(line: &[u8], n: usize) -> &[u8] {
    if !line.contains(&b'\t') {
        return line;
    }
    let mut at = 0;
    for _ in 1..n {
        match line[at..].iter().position(|&b| b == b'\t') {
            Some(k) => at += k + 1,
            None => return b"",
        }
    }
    &line[at..]
}

fn class(name: &[u8], c: u32) -> bool {
    let Some(ch) = char::from_u32(c) else { return false };
    if !ch.is_ascii() {
        return false;
    }
    let b = ch as u8;
    match name {
        b"alpha" => b.is_ascii_alphabetic(),
        b"digit" => b.is_ascii_digit(),
        b"alnum" => b.is_ascii_alphanumeric(),
        b"upper" => b.is_ascii_uppercase(),
        b"lower" => b.is_ascii_lowercase(),
        b"space" => matches!(b, b' ' | 9..=13),
        b"blank" => b == b' ' || b == b'\t',
        b"punct" => b.is_ascii_punctuation(),
        b"print" => (0x20..0x7f).contains(&b),
        b"graph" => (0x21..0x7f).contains(&b),
        b"cntrl" => b < 0x20 || b == 0x7f,
        b"xdigit" => b.is_ascii_hexdigit(),
        b"word" => b.is_ascii_alphanumeric() || b == b'_',
        _ => false,
    }
}

fn units(b: &[u8], utf8: bool) -> Vec<u32> {
    if utf8 {
        if let Ok(s) = std::str::from_utf8(b) {
            return s.chars().map(|c| c as u32).collect();
        }
    }
    b.iter().map(|&x| x as u32).collect()
}

const QUOTED: u32 = 1 << 31;

fn pattern_units(pattern: &[u8], utf8: bool) -> Vec<u32> {
    let raw = units(pattern, utf8);
    let mut out = Vec::new();
    let mut it = raw.into_iter();
    while let Some(c) = it.next() {
        if c == '\\' as u32 {
            out.push(it.next().unwrap_or(c) | QUOTED);
        } else { out.push(c); }
    }
    out
}

/// Whether an expanded shell word requests pathname expansion. Backslashes
/// remain literal when no unquoted metacharacter requests that expansion.
pub fn glob_pattern(pattern: &[u8]) -> bool {
    let pat = pattern_units(pattern, false);
    pat.iter().enumerate().any(|(i, &c)| c == '*' as u32 || c == '?' as u32 ||
        (c == '[' as u32 && bracket(&pat, i, 0).is_some()))
}

/// A bracket expression at `pat[i]` (`[`): whether `c` is in it and where the
/// expression ends, or None when no `]` closes it and the `[` is a character.
fn bracket(pat: &[u32], i: usize, c: u32) -> Option<(bool, usize)> {
    let mut k = i + 1;
    let negate = matches!(pat.get(k), Some(&x) if x == '!' as u32 || x == '^' as u32);
    if negate {
        k += 1;
    }
    let mut hit = false;
    let mut first = true;
    loop {
        let x = *pat.get(k)?;
        if x == ']' as u32 && !first {
            return Some((hit != negate, k + 1));
        }
        first = false;
        if x == '[' as u32 && pat.get(k + 1) == Some(&(':' as u32)) {
            let st = k + 2;
            let mut e = st;
            while e + 1 < pat.len() && !(pat[e] == ':' as u32 && pat[e + 1] == ']' as u32) {
                e += 1;
            }
            if e + 1 < pat.len() {
                let name: Vec<u8> = pat[st..e].iter().map(|&u| u as u8).collect();
                if class(&name, c) {
                    hit = true;
                }
                k = e + 2;
                continue;
            }
        }
        if pat.get(k + 1) == Some(&('-' as u32)) && matches!(pat.get(k + 2), Some(&y) if y != ']' as u32) {
            let y = pat[k + 2] & !QUOTED;
            if (x & !QUOTED) <= c && c <= y {
                hit = true;
            }
            k += 3;
            continue;
        }
        if (x & !QUOTED) == c {
            hit = true;
        }
        k += 1;
    }
}

fn glob(pat: &[u32], name: &[u32]) -> bool {
    let (mut pi, mut ni) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while ni < name.len() {
        let mut step = false;
        if pi < pat.len() {
            let x = pat[pi];
            if x == '*' as u32 {
                star = Some((pi, ni));
                pi += 1;
                continue;
            }
            if x == '?' as u32 {
                pi += 1;
                ni += 1;
                step = true;
            } else if x == '[' as u32 {
                match bracket(pat, pi, name[ni]) {
                    Some((true, end)) => {
                        pi = end;
                        ni += 1;
                        step = true;
                    }
                    Some((false, _)) => {}
                    None => {
                        if name[ni] == x {
                            pi += 1;
                            ni += 1;
                            step = true;
                        }
                    }
                }
            } else if (x & !QUOTED) == name[ni] {
                pi += 1;
                ni += 1;
                step = true;
            }
        }
        if step {
            continue;
        }
        match star {
            Some((sp, sn)) => {
                pi = sp + 1;
                ni = sn + 1;
                star = Some((sp, sn + 1));
            }
            None => return false,
        }
    }
    while pi < pat.len() && pat[pi] == '*' as u32 {
        pi += 1;
    }
    pi == pat.len()
}

/// Shell pattern matching, including backslash quotation for the Yarn
/// pathname-expansion caller. Ordinary workspace patterns reject backslashes.
pub fn fnmatch(pattern: &[u8], name: &[u8]) -> bool {
    let utf8 = utf8_locale();
    glob(&pattern_units(pattern, utf8), &units(name, utf8))
}

fn random_tail() -> [u8; 6] {
    const SET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let mut raw = [0u8; 6];
    let read = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut raw));
    if read.is_err() {
        let (s, n) = crate::os::now();
        let mut x = (s as u64) ^ ((n as u64) << 20) ^ ((std::process::id() as u64) << 40);
        for b in raw.iter_mut() {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            *b = (x >> 33) as u8;
        }
    }
    let mut out = [0u8; 6];
    for (o, r) in out.iter_mut().zip(raw.iter()) {
        *o = SET[(*r as usize) % SET.len()];
    }
    out
}

fn with_tail(prefix: &[u8]) -> PathBuf {
    let mut name = prefix.to_vec();
    name.extend_from_slice(&random_tail());
    p(&name)
}

/// `mktemp <prefix>XXXXXX`: a new file, mode 0600, whose name nothing else
/// has. None where mktemp fails.
pub fn mktemp(prefix: &[u8]) -> Option<PathBuf> {
    for _ in 0..100 {
        let path = with_tail(prefix);
        match std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path) {
            Ok(_) => return Some(path),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return None,
        }
    }
    None
}

/// `mktemp -d <prefix>XXXXXX`
pub fn mktemp_dir(prefix: &[u8]) -> Option<PathBuf> {
    for _ in 0..100 {
        let path = with_tail(prefix);
        match std::fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => return Some(path),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return None,
        }
    }
    None
}

/// `${TMPDIR:-/tmp}/<name>.`, the prefix of a scratch file.
pub fn tmp_prefix(name: &str) -> Vec<u8> {
    let mut dir = match std::env::var_os("TMPDIR") {
        Some(d) if !d.is_empty() => d.as_bytes().to_vec(),
        _ => b"/tmp".to_vec(),
    };
    dir.push(b'/');
    dir.extend_from_slice(name.as_bytes());
    dir.push(b'.');
    dir
}

/// `mkdir -p`
pub fn mkdir_p(path: &Path) -> bool {
    std::fs::DirBuilder::new().recursive(true).mode(0o777).create(path).is_ok() && is_dir(path)
}

/// `cmp -s a b`: the same bytes. False where either cannot be read.
pub fn same_bytes(a: &Path, b: &Path) -> bool {
    let (Ok(mut fa), Ok(mut fb)) = (std::fs::File::open(a), std::fs::File::open(b)) else { return false };
    let (mut ba, mut bb) = (vec![0u8; 65536], vec![0u8; 65536]);
    loop {
        let na = match read_full(&mut fa, &mut ba) {
            Ok(n) => n,
            Err(_) => return false,
        };
        let nb = match read_full(&mut fb, &mut bb) {
            Ok(n) => n,
            Err(_) => return false,
        };
        if na != nb || ba[..na] != bb[..nb] {
            return false;
        }
        if na == 0 {
            return true;
        }
    }
}

fn read_full(f: &mut std::fs::File, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match f.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// `cp src dst`, as its exit status: 0, or 1 where cp fails. The target is
/// opened for writing and cut to nothing before the bytes go in, as cp does
/// it, so a copy that fails part way leaves what cp would leave; a target
/// that is not there is made with the source's mode under the umask.
pub fn cp(src: &Path, dst: &Path) -> i32 {
    // cp will follow a link to a file, but refuses a dangling destination
    // link rather than creating a file at its missing target.
    if is_link(dst) && !exists(dst) { return 1; }
    let Ok(mut from) = std::fs::File::open(src) else { return 1 };
    let Ok(meta) = from.metadata() else { return 1 };
    if meta.is_dir() {
        return 1;
    }
    // cp refuses to copy a file onto itself.
    if let Ok(d) = std::fs::metadata(dst) {
        if d.dev() == meta.dev() && d.ino() == meta.ino() {
            return 1;
        }
    }
    let mode = meta.permissions().mode() & 0o777;
    let Ok(mut to) = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(mode).open(dst) else {
        return 1;
    };
    let mut buf = vec![0u8; 65536];
    loop {
        match from.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    return 1;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return 1,
        }
    }
    0
}

fn remove_tree(path: &Path) -> bool {
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        // Gone already: rm -f does not count it.
        return true;
    };
    if !meta.is_dir() {
        return std::fs::remove_file(path).is_ok() || !present(path);
    }
    let mut ok = true;
    match std::fs::read_dir(path) {
        Ok(entries) => {
            for e in entries {
                match e {
                    Ok(e) => ok &= remove_tree(&e.path()),
                    Err(_) => ok = false,
                }
            }
        }
        Err(_) => ok = false,
    }
    ok & (std::fs::remove_dir(path).is_ok() || !present(path))
}

/// `rm -rf path`, as its exit status: 0, or 1 where something could not be
/// removed. Like rm it removes what it can and goes on past what it cannot,
/// and it removes a link, never what the link names.
pub fn rm_rf(path: &Path) -> i32 {
    if remove_tree(path) {
        0
    } else {
        1
    }
}

/// `rm -f path`
pub fn rm_f(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// Writes a file's bytes under a temporary name beside it and renames it into
/// place (`mktemp <dir>/.<leaf>XXXXXX`, `mv -f`). False where either fails,
/// with the temporary file removed.
pub fn write_renamed(tmp_prefix: &[u8], target: &Path, body: &[u8]) -> bool {
    let Some(tmp) = mktemp(tmp_prefix) else { return false };
    let wrote = std::fs::OpenOptions::new().write(true).truncate(true).open(&tmp).and_then(|mut f| f.write_all(body)).is_ok();
    if wrote && std::fs::rename(&tmp, target).is_ok() {
        return true;
    }
    rm_f(&tmp);
    false
}

/// Appends to a file, creating it.
pub fn append(path: &Path, body: &[u8]) -> bool {
    std::fs::OpenOptions::new().create(true).append(true).mode(0o666).open(path).and_then(|mut f| f.write_all(body)).is_ok()
}

/// `cat file 2>/dev/null` into `$(...)`: the bytes without NUL and without
/// the newlines that end them, or None where cat fails.
pub fn cat_captured(path: &Path) -> Option<Vec<u8>> {
    let mut b: Vec<u8> = std::fs::read(path).ok()?.into_iter().filter(|&x| x != 0).collect();
    while b.last() == Some(&b'\n') {
        b.pop();
    }
    Some(b)
}

/// A directory as `cd -P <dir> && printf %s "$PWD"` names it, from the
/// directory `from` a relative one is entered from. None where cd fails.
pub fn cd_physical(from: &Path, dir: &Path) -> Option<PathBuf> {
    let target = if dir.is_absolute() { dir.to_path_buf() } else { from.join(dir) };
    let real = std::fs::canonicalize(&target).ok()?;
    if is_dir(&real) {
        Some(real)
    } else {
        None
    }
}

/// `dirname` and `basename` of a path, as the commands print them.
pub fn dirname(path: &[u8]) -> Vec<u8> {
    let mut end = path.len();
    while end > 1 && path[end - 1] == b'/' {
        end -= 1;
    }
    let t = &path[..end];
    match t.iter().rposition(|&b| b == b'/') {
        None => b".".to_vec(),
        Some(0) => b"/".to_vec(),
        Some(k) => {
            let mut e = k;
            while e > 1 && t[e - 1] == b'/' {
                e -= 1;
            }
            t[..e].to_vec()
        }
    }
}

pub fn basename(path: &[u8]) -> Vec<u8> {
    let mut end = path.len();
    while end > 1 && path[end - 1] == b'/' {
        end -= 1;
    }
    let t = &path[..end];
    if t == b"/" {
        return b"/".to_vec();
    }
    match t.iter().rposition(|&b| b == b'/') {
        None => t.to_vec(),
        Some(k) => t[k + 1..].to_vec(),
    }
}
