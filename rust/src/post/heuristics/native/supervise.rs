//! One read-only core child; process ownership follows pre/budget.rs:
//! observe without reaping, signal the owned group, then reap its leader.
use super::{scan, Cause, Evidence, Format, Inspection, SCAN_TIME};
use crate::{json::{self, Value}, os, outcome::{Action, Form, Outcome}, post::{jv, snapshot::Store}};
use std::{io::{Read, Write}, os::unix::process::CommandExt, path::Path, process::{Child, Command, Stdio}, time::{Duration, Instant}};

const RESPONSE_BYTES: u64 = 64 * 1024;
const POST_LIMIT: Duration = Duration::from_secs(25);
struct Owned { child: Child, reaped: bool }
impl Owned {
    fn finish(&mut self) -> std::io::Result<std::process::ExitStatus> {
        os::kill_group(self.child.id(), os::SIGKILL);
        let status = self.child.wait(); self.reaped = true; status
    }
}
impl Drop for Owned { fn drop(&mut self) { if !self.reaped { let _ = self.finish(); } } }
fn observed(outcome: Outcome, dir: &Path) -> Inspection {
    Inspection::Incomplete(Cause::Observed(outcome.describe(Action::NativeInspection(dir),Form::Action)))
}

pub(crate) fn inspect(store: &Store, post_started: Instant) -> Inspection {
    let dir = store.project.join("node_modules/.bin");
    let until = (Instant::now()+SCAN_TIME).min(post_started+POST_LIMIT);
    if Instant::now() >= until { return observed(Outcome::Deadline,&dir) }
    let exe = match std::env::current_exe() { Ok(exe) => exe, Err(e) => return observed(Outcome::Io(Err(e)),&dir) };
    let mut command = Command::new(exe);
    command.arg("native-inspect").arg(&dir).arg(store.path(&store.id,b"bins.list"));
    execute(command,&dir,until)
}

fn execute(mut command: Command, dir: &Path, until: Instant) -> Inspection {
    if Instant::now() >= until { return observed(Outcome::Deadline,dir) }
    let child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).process_group(0).spawn();
    let mut owned = match child {
        Ok(child) => Owned { child, reaped: false },
        Err(e) => return observed(Outcome::StartFailure(e),dir),
    };
    let stdout = owned.child.stdout.take().unwrap();
    // Drain while waiting so even maximally escaped paths cannot fill a pipe.
    // The core child starts no children and writes exactly one small result.
    let reader = std::thread::Builder::new().spawn(move || {
        let mut bytes = Vec::new();
        stdout.take(RESPONSE_BYTES+1).read_to_end(&mut bytes).map(|_| bytes)
    });
    let reader = match reader { Ok(reader) => reader, Err(e) => return observed(Outcome::Io(Err(e)),dir) };
    let outcome = loop {
        if Instant::now() >= until { break Outcome::Deadline }
        match os::child_exited_unreaped(owned.child.id()) {
            Ok(true) => break match owned.finish() { Ok(s) => Outcome::Finished(s), Err(e) => Outcome::StatusFailure(e) },
            Ok(false) => (),
            Err(e) => {
                if e.raw_os_error() == Some(10) { owned.reaped = true; }
                break Outcome::StatusFailure(e)
            },
        }
        std::thread::sleep(Duration::from_millis(5).min(until.saturating_duration_since(Instant::now())));
    };
    if !owned.reaped { let _ = owned.finish(); }
    let bytes = reader.join();
    if !outcome.success() { return observed(outcome,dir) }
    if Instant::now() >= until { return observed(Outcome::Deadline,dir) }
    match bytes {
        Ok(Ok(bytes)) if bytes.len() <= RESPONSE_BYTES as usize => decode(&bytes),
        Ok(Err(e)) => observed(Outcome::Io(Err(e)),dir),
        _ => Inspection::Incomplete(Cause::Response),
    }
}

fn encode(result: &Inspection) -> Vec<u8> {
    let text = |b: &[u8]| Value::Str(b.to_vec());
    let fields = match result {
        Inspection::NotNative => vec![text(b"not-native")],
        Inspection::Incomplete(cause) => vec![text(b"incomplete"),text(&cause.text())],
        Inspection::NativeImage(format,ev) => vec![text(b"native"),text(match format { Format::Elf=>b"ELF",Format::Mach=>b"Mach-O",Format::Pe=>b"PE" }),
            text(&ev.name),Value::Num(ev.offset.to_string()),Value::Num(ev.kind.to_string())],
    };
    jv::dump(&Value::Arr(fields))
}
fn decode(bytes: &[u8]) -> Inspection {
    fn parse(bytes: &[u8]) -> Option<Inspection> {
        let Value::Arr(xs) = json::parse_one(bytes).ok()? else { return None };
        match xs.as_slice() {
            [Value::Str(tag)] if tag == b"not-native" => Some(Inspection::NotNative),
            [Value::Str(tag),Value::Str(cause)] if tag == b"incomplete" && !cause.is_empty() => Some(Inspection::Incomplete(Cause::Observed(cause.clone()))),
            [Value::Str(tag),Value::Str(format),Value::Str(name),Value::Num(offset),Value::Num(kind)] if tag == b"native" && !name.is_empty() && !name.contains(&b'/') => {
                let format = match format.as_slice() { b"ELF"=>Format::Elf,b"Mach-O"=>Format::Mach,b"PE"=>Format::Pe,_=>return None };
                Some(Inspection::NativeImage(format,Evidence { name:name.clone(),offset:offset.parse().ok()?,kind:kind.parse().ok()? }))
            },
            _ => None,
        }
    }
    parse(bytes).unwrap_or(Inspection::Incomplete(Cause::Response))
}

pub(crate) fn child_main() -> i32 {
    // Preserve path bytes: main's command selector is lossy, these paths aren't.
    let args: Vec<_> = std::env::args_os().skip(2).collect();
    if args.len() != 2 { return 2 }
    let result = scan(Path::new(&args[0]),Path::new(&args[1]));
    if std::io::stdout().write_all(&encode(&result)).is_err() { 1 } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_children_and_bad_results_are_incomplete() {
        let dir = Path::new("fixture");
        for script in ["exit 7", "printf malformed", "sleep 10"] {
            let mut c = Command::new("/bin/sh"); c.args(["-c",script]);
            let start = Instant::now();
            assert!(matches!(execute(c,dir,start+Duration::from_millis(150)),Inspection::Incomplete(_)));
            assert!(start.elapsed() < Duration::from_secs(2));
        }
        assert!(matches!(execute(Command::new("/missing-native-inspector"),dir,Instant::now()+SCAN_TIME),Inspection::Incomplete(_)));
        for result in [Inspection::NotNative,Inspection::Incomplete(Cause::Budget("fixture")),
            Inspection::NativeImage(Format::Mach,Evidence{name:b"native".to_vec(),offset:4096,kind:6})] {
            assert_eq!(decode(&encode(&result)).reason(),result.reason());
        }
    }
}
