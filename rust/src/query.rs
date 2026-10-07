//! Read-only queries of the readers, for the batteries and the measurements
//! that sourced the bash guard to ask the same things. None of them is on a
//! hook's path and none judges a command: each answers what one reader
//! function returns. A query is one JSON object on a line of stdin and its
//! answer one JSON object on a line of stdout, in order. A line that is not a
//! query is answered `{"error": ...}`, and the exit status is then 2.
//!
//! Bytes go out twice, as `text` (a JSON string, which cannot hold every
//! byte) and as `hex`. A query gives a text as `text`, or as `hex` where a
//! JSON string cannot hold it.

use crate::core::{Core, Run};
use crate::jq::{self, J};
use crate::json::{self, Value};
use crate::{extract, lex, manager};

type W = Vec<u8>;

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{:02x}", x)).collect()
}

fn unhex(s: &str) -> Option<W> {
    if s.len() % 2 != 0 || !s.is_ascii() {
        return None;
    }
    s.as_bytes().chunks(2).map(|c| u8::from_str_radix(std::str::from_utf8(c).ok()?, 16).ok()).collect()
}

fn bytes(b: &[u8]) -> J {
    jq::obj(vec![("text", jq::arg(b)), ("hex", jq::s(&hex(b)))])
}

fn text_of(q: &Value, key: &str) -> Option<W> {
    match q.get("hex").and_then(Value::as_str) {
        Some(h) => unhex(h),
        None => q.get(key).and_then(Value::as_bytes),
    }
}

fn words_of(q: &Value) -> Option<Vec<W>> {
    match q.get("words") {
        Some(Value::Arr(v)) => v.iter().map(Value::as_bytes).collect(),
        _ => None,
    }
}

fn each(input: &[u8], mut answer: impl FnMut(&Value) -> Result<J, &'static str>) -> i32 {
    use std::io::Write;
    let mut out = String::new();
    let mut bad = false;
    for line in input.split(|&b| b == b'\n') {
        if line.iter().all(|b| b.is_ascii_whitespace()) {
            continue;
        }
        let j = match json::parse_one(line) {
            Ok(q) => answer(&q),
            Err(_) => Err("the line is not one JSON value"),
        };
        let j = j.unwrap_or_else(|why| {
            bad = true;
            jq::obj(vec![("error", jq::s(why))])
        });
        out.push_str(&jq::compact(&j));
        out.push('\n');
    }
    let mut so = std::io::stdout().lock();
    if so.write_all(out.as_bytes()).is_err() || so.flush().is_err() {
        return 1;
    }
    if bad {
        2
    } else {
        0
    }
}

/// `safedeps-core reader`: one reader function of `Run`, in one reading.
///
///   {"op":"statements","reading":R,"text":T}
///       `Run::statements` (`command_statements`): {"records":{text,hex}}
///   {"op":"raw-texts","reading":R,"text":T}
///       `Run::raw_texts` (`command_payload_raw_texts`): {"texts":[{text,hex}]}
///   {"op":"lex-payloads","reading":R,"view":"cscripts"|"substs","text":T}
///       `Run::lex_payloads`: {"payloads":[{"kind":"S"|"E"|"B",text,hex}]}
///
/// R is bash, zsh or dash. Every answer ends with `failed` and `diverge`, the
/// run's marks after the call. Each query has a run of its own.
pub fn reader(input: &[u8]) -> i32 {
    let core = Core::new();
    each(input, |q| {
        let reading = q.get("reading").and_then(Value::as_str).and_then(lex::Reading::parse).ok_or("reading is bash, zsh or dash")?;
        let text = text_of(q, "text").ok_or("no text: give text, or hex")?;
        let mut run = Run::new(&core);
        run.reading = Some(reading);
        let mut fields = match q.get("op").and_then(Value::as_str) {
            Some("statements") => vec![("records", bytes(&run.statements(&text)))],
            Some("raw-texts") => vec![("texts", J::Arr(run.raw_texts(&text).iter().map(|t| bytes(t)).collect()))],
            Some("lex-payloads") => {
                let view = match q.get("view").and_then(Value::as_str) {
                    Some("cscripts") => "cscripts",
                    Some("substs") => "substs",
                    _ => return Err("lex-payloads takes view cscripts or substs"),
                };
                let payloads = run.lex_payloads(&text, view);
                vec![("payloads", J::Arr(payloads.iter().map(|(k, t)| jq::obj(vec![("kind", jq::s(&(*k as char).to_string())), ("text", jq::arg(t)), ("hex", jq::s(&hex(t)))])).collect()))]
            }
            _ => return Err("op is statements, raw-texts or lex-payloads"),
        };
        fields.push(("failed", J::Bool(run.failed)));
        fields.push(("diverge", J::Bool(run.diverge)));
        Ok(jq::obj(fields))
    })
}

/// `safedeps-core manager`: the manager reader's tables and readings.
///
///   {"op":"npa-local","word":W}
///       `extract::npa_is_local` (`safedeps_npa_is_local`): {"local":bool}
///   {"op":"npm-read","words":[W...],"table":"plain"|"other"}
///       `Reader::npm_reading` (`safedeps_npm_read_args`, and under
///       `safedeps_npm_as_other` for "other"; "plain" where none is given):
///       {"reads":bool,"other_applies":bool,"words":[W],
///        "switches":[[name,bool]],"values":[[name,value]]}. `reads` false
///       is a reading that does not close. The words are the ones after
///       `npm`.
///   {"op":"read","words":[W...]}
///       `Reader::read` (`safedeps_manager_read`), the manager's own word
///       first: {"family","kind","localbin","roles","texts":[W]}. `roles` has
///       one character for each word, `-` where the reader gave none.
///   {"op":"option-class","family":F,"path":P,"option":W}
///       `manager::option_class` and `manager::long_option`: whether the
///       table has the option take a value after the command path P ("" for
///       before the command): {"class":"v"|...|null,"long":W}
pub fn manager(input: &[u8]) -> i32 {
    let rx = manager::Regexes::new();
    let xrx = extract::XRegexes::new();
    each(input, |q| match q.get("op").and_then(Value::as_str) {
        Some("npa-local") => {
            let word = text_of(q, "word").ok_or("no word: give word, or hex")?;
            Ok(jq::obj(vec![("local", J::Bool(extract::npa_is_local(&xrx, &word)))]))
        }
        Some("npm-read") => {
            let words = words_of(q).ok_or("words is an array of strings")?;
            let other = match q.get("table").and_then(Value::as_str) {
                None | Some("plain") => false,
                Some("other") => true,
                _ => return Err("table is plain or other"),
            };
            let mut rd = manager::Reader::new(&rx);
            let r = rd.npm_reading(&words, other);
            Ok(jq::obj(vec![
                ("reads", J::Bool(r.reads)),
                ("other_applies", J::Bool(r.other_applies)),
                ("words", J::Arr(r.words.iter().map(|w| jq::arg(w)).collect())),
                ("switches", J::Arr(r.switches.iter().map(|(k, v)| J::Arr(vec![jq::arg(k), J::Bool(*v)])).collect())),
                ("values", J::Arr(r.values.iter().map(|(k, v)| J::Arr(vec![jq::arg(k), jq::arg(v)])).collect())),
            ]))
        }
        Some("read") => {
            let words = words_of(q).ok_or("words is an array of strings")?;
            let mut rd = manager::Reader::new(&rx);
            rd.read(&words);
            let roles: String = (0..words.len()).map(|k| rd.role.get(k).copied().filter(|&r| r != 0).unwrap_or(b'-') as char).collect();
            let texts = (0..words.len()).map(|k| jq::arg(rd.text.get(k).map(Vec::as_slice).unwrap_or(b""))).collect();
            Ok(jq::obj(vec![("family", jq::s(&rd.family)), ("kind", jq::s(&rd.kind)), ("localbin", J::Bool(rd.localbin)), ("roles", jq::s(&roles)), ("texts", J::Arr(texts))]))
        }
        Some("option-class") => {
            let family = q.get("family").and_then(Value::as_str).ok_or("no family")?;
            let path = q.get("path").and_then(Value::as_str).unwrap_or("");
            let option = text_of(q, "option").ok_or("no option: give option, or hex")?;
            let class = manager::option_class(family, path, &option).map(|c| jq::s(&(c as char).to_string())).unwrap_or(J::Null);
            Ok(jq::obj(vec![("class", class), ("long", jq::arg(&manager::long_option(family, path, &option)))]))
        }
        _ => Err("op is npa-local, npm-read, read or option-class"),
    })
}
