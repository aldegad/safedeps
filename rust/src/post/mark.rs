//! The judgment mark: one file a post run writes when it takes a call and
//! removes when the judgment of that call returns. A mark that outlives its
//! run is the record of a judgment the run did not finish: the runtime's kill
//! at 30 s, a panic, or any other end the code did not choose. A mark is never
//! a lock on its judgment, and nothing waits on it.
//!
//! The file is `judging/<pid>-<start>.json` under `SAFEDEPS_HOME`, named by
//! the process that holds it: its pid and the start the kernel stored for it
//! (`process::start`). Two runs alive at once have two names, and a pid the
//! kernel hands out again comes with another start, so no run writes or
//! removes another run's mark. A run removes only the path it wrote.
//!
//! The next post run reports, once, each mark whose run is gone
//! (`report_gone`): one NOT JUDGED line in advisory.log. The run that says a
//! mark holds the mark file's own lock while it does (`Opened`); no run
//! waits for that lock.
use super::{jv, process::{self, Holder}, report::cat, sh};
use crate::{json::Value, os, outcome::{Action, Form, Outcome}, state};
use std::{fs::{File, TryLockError}, io::{ErrorKind, Read, Write}, os::unix::ffi::OsStrExt, path::{Path, PathBuf}};

/// The marks' directory. It is derived from `SAFEDEPS_HOME` and from nothing
/// else: a mark is the record of a judgment owed in that home, so it lives
/// with the advisory.log of the same home.
pub fn dir(home: &Path) -> PathBuf { home.join("judging") }

/// What the hook's answer says after the fact of a mark that was not written,
/// for a reader who does not know what a mark is for.
const UNMARKED: &[u8] = b"Without that mark, a judgment the runtime kills before it returns leaves no record.";

/// The headline of the hook's answer for a run that starts no judgment.
const UNJUDGED: &[u8] = b"safedeps: this install was not judged.";

/// What a run whose mark and log line were both not written says of why it
/// starts no judgment, and that it changed nothing.
const UNRECORDED: &[u8] = b"With neither, a judgment the runtime killed would leave no record, so this run did not start one.\nNo closure check ran, and nothing was rolled back.";

/// This run's mark: what it wrote, or what it says in place of a mark.
pub struct Mark(State);

enum State {
    /// The mark is on disk until `close` removes it.
    Written(PathBuf),
    /// No mark, and advisory.log took the line that says so. The judgment
    /// goes on, and this is the last paragraph of the hook's answer.
    Logged(Vec<u8>),
    /// Neither the mark nor that line was written. No judgment starts, and
    /// this is the hook's answer (decision 6).
    Unrecorded(Vec<u8>),
    /// Removed, or its words already given.
    Spent,
}

impl Mark {
    /// Writes this run's mark for a call it is taking. The caller removes the
    /// call's own records only after this returns, so where the mark is
    /// written, a kill at any point leaves at least one of the two on disk. A
    /// mark is written whole, through a
    /// temporary name and a rename, so a mark is never read half written; the
    /// temporary file starts with a dot. A mark that cannot be written is said
    /// in advisory.log at once (`not_written`).
    pub fn open(home: &Path, command: &[u8], project: &Path, tool_use_id: Option<&str>) -> Self {
        let pid = std::process::id();
        let pid_text = pid.to_string();
        let Some(start) = process::start(pid) else {
            let unstarted = cat(&[b"this run wrote no judgment mark: the native process query gave no start for pid ", pid_text.as_bytes()]);
            let logged = state::log_advisory(home, &cat(&[b"post-verify: ", &unstarted, b". Command: ", command]));
            return Self::not_written(home, &unstarted, logged, command, project)
        };
        let path = dir(home).join(format!("{}-{}.json", pid, start));
        let opened = os::utc_stamp(os::wall(os::WallRole::JudgmentMarkOpened).seconds());
        let value = jv::obj(vec![
            ("pid", jv::s(pid_text.as_bytes())), ("start", jv::s(start.to_string().as_bytes())),
            ("opened_at", jv::s(opened.as_bytes())),
            ("tool_use_id", tool_use_id.map(|id| jv::s(id.as_bytes())).unwrap_or(Value::Null)),
            ("project", jv::s(sh::bytes(project))), ("command", jv::s(command)),
        ]);
        match state::write_state_file(&path, &jv::dump(&value)) {
            Ok(()) => Self(State::Written(path)),
            Err(error) => {
                let unwritable = cat(&[b"this run wrote no judgment mark: ", &Outcome::Io(Err(error)).describe(Action::WriteOf(path.as_path()), Form::Action)]);
                let logged = state::log_advisory(home, &cat(&[b"post-verify: ", &unwritable, b". Command: ", command]));
                Self::not_written(home, &unwritable, logged, command, project)
            }
        }
    }

    /// A run whose mark was not written, after the caller tried the
    /// advisory.log line for it (decision 6). Where the log took the line, the
    /// judgment goes on: the line outlives a later kill of this run, and the
    /// hook's answer says it too when the run returns. Where it did not,
    /// nothing this run leaves would say that a kill cut its judgment, so it
    /// starts none, and its answer says so, with what each write returned.
    /// That answer follows the unfinished-rollback report: a headline, then
    /// its facts. Nothing runs between the two writes and that answer but
    /// the end of `Call::take`; the confirmed record is not read.
    fn not_written(home: &Path, fact: &[u8], logged: Outcome, command: &[u8], project: &Path) -> Self {
        if logged.success() { return Self(State::Logged(cat(&[b"safedeps: ", fact, b". ", UNMARKED]))) }
        let unlogged = logged.describe(Action::WriteOf(state::advisory_path(home).as_path()), Form::Action);
        let mut said = fact.to_vec();
        if let Some(first) = said.first_mut() { *first = first.to_ascii_uppercase(); }
        Self(State::Unrecorded(cat(&[UNJUDGED, b"\n\n", &said, b".\nIt wrote no line to advisory.log either: ", &unlogged, b".\n",
            UNRECORDED, b"\nCommand: ", command, b"\nProject: ", sh::bytes(project)])))
    }

    /// The hook's answer for a run that wrote neither its mark nor the
    /// advisory.log line for it, given once. `run::main` gives it in place of
    /// a judgment and starts none. None for every other run.
    pub fn unjudged(&mut self) -> Option<Vec<u8>> {
        let State::Unrecorded(report) = &mut self.0 else { return None };
        let report = std::mem::take(report);
        self.0 = State::Spent;
        Some(report)
    }

    /// The line the hook's answer gives for this run's mark: one where the
    /// mark was not written and advisory.log took the line for it, none
    /// otherwise. `run::main` puts it last in the answer, after the
    /// judgment's own message.
    pub fn unwritten(&mut self) -> Option<Vec<u8>> {
        let State::Logged(line) = &mut self.0 else { return None };
        let line = std::mem::take(line);
        self.0 = State::Spent;
        Some(line)
    }

    /// Removes this run's mark once its judgment returned, whatever it
    /// returned. A mark that cannot be removed is said in advisory.log, beside
    /// the judgment's own lines, and it gets the record that its judgment
    /// returned (`add_record`), so the run that claims it later removes it
    /// and does not report a judgment that returned as one that did not. A
    /// record that cannot be added either is said in the same line.
    pub fn close(&mut self, home: &Path, command: &[u8]) {
        let State::Written(path) = &self.0 else { return };
        let path = path.clone();
        self.0 = State::Spent;
        if let Err(error) = std::fs::remove_file(&path) {
            let added = add_record(&path, Added::Returned);
            let unadded = if added.success() { Vec::new() }
                else { cat(&[b". The record that it returned was not added to it either: ", &added.describe(Action::WriteOf(&path), Form::Action)]) };
            state::log_advisory(home, &cat(&[b"post-verify: the judgment of this call returned, and its judgment mark ", sh::bytes(&path),
                b" was not removed: ", &Outcome::Io(Err(error)).describe(Action::Removal, Form::Action), &unadded, b". Command: ", command]));
        }
    }
}

/// A record added to a file in `judging/` that stays: that the judgment of
/// its call returned (`Mark::close`), or that a NOT JUDGED line for it was
/// written (`report_gone`). Either way no run says it.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Added { Returned, Said }

impl Added {
    fn key(self) -> &'static str { match self { Added::Returned => "returned_at", Added::Said => "said_at" } }
}

/// Adds `record` to the file at `path`: one JSON object whose one field is
/// the record's key, with the UTC time, on a line of its own after the bytes
/// that are there, whatever they are. The file is opened to append and never
/// created. Appending needs no change to `judging/`, which is what the
/// removal or the claim that failed did not get.
fn add_record(path: &Path, record: Added) -> Outcome {
    let role = match record { Added::Returned => os::WallRole::JudgmentMarkReturned, Added::Said => os::WallRole::JudgmentMarkSaid };
    let value = jv::obj(vec![(record.key(), jv::s(os::utc_stamp(os::wall(role).seconds()).as_bytes()))]);
    Outcome::Io(std::fs::OpenOptions::new().append(true).open(path).and_then(|mut file| file.write_all(&cat(&[b"\n", &jv::dump(&value), b"\n"]))))
}

/// The record `add_record` wrote as `line`, if it is one.
fn record(line: &[u8]) -> Option<Added> {
    let read = jv::read(line);
    let [Value::Obj(fields)] = read.values.as_slice() else { return None };
    let [(key, Value::Str(_))] = fields.as_slice() else { return None };
    if read.failed { return None }
    [Added::Returned, Added::Said].into_iter().find(|added| key.as_slice() == added.key().as_bytes())
}

/// A file's own bytes, and the records added after them: each line at its
/// end that is one record (`record`), read from the last line back. A record
/// starts a line, so the bytes before it are left as they were, broken or not.
fn split_records(bytes: &[u8]) -> (&[u8], Vec<Added>) {
    let (mut own, mut added) = (bytes, Vec::new());
    loop {
        let lines = own.strip_suffix(b"\n").unwrap_or(own);
        let Some(at) = lines.iter().rposition(|b| *b == b'\n') else { return (own, added) };
        let Some(found) = record(&lines[at + 1..]) else { return (own, added) };
        added.push(found);
        own = &lines[..at];
    }
}

/// `<pid>-<start>` as `Mark::open` spells it: two runs of digits with no
/// leading zero, a pid from 1 to i32::MAX, which is what the kernel hands out,
/// and a start above 0.
fn pid_start(text: &[u8]) -> Option<(u32, u64)> {
    let dash = text.iter().position(|b| *b == b'-')?;
    let pid = std::str::from_utf8(&text[..dash]).ok()?.parse::<u32>().ok().filter(|p| *p > 0 && i32::try_from(*p).is_ok())?;
    let start = std::str::from_utf8(&text[dash + 1..]).ok()?.parse::<u64>().ok().filter(|s| *s > 0)?;
    (format!("{}-{}", pid, start).as_bytes() == text).then_some((pid, start))
}

/// A mark's file name, `<pid>-<start>.json`. No other name in `judging/` is a
/// mark: a temporary file (its name starts with a dot), a claim, or a file
/// this code did not write.
fn mark_name(name: &[u8]) -> Option<(u32, u64)> { pid_start(name.strip_suffix(b".json")?) }

/// A claim's file name, `<pid>-<start>.json.<pid>-<start>.claim`: the name of
/// the mark it took, then the pid and start of the run that took it.
fn claim_name(name: &[u8]) -> Option<((u32, u64), (u32, u64))> {
    let name = name.strip_suffix(b".claim")?;
    let at = name.windows(6).position(|w| w == b".json.")?;
    Some((pid_start(&name[..at])?, pid_start(&name[at + 6..])?))
}

/// Reports in advisory.log, once, each mark in this home whose run is gone
/// (`process::holder`): a run the kernel holds under the mark's pid with the
/// mark's start is alive, and one whose start the kernel does not give is not
/// known, and both marks are left as they are. A post run calls this at its
/// start, before it takes a call of its own.
///
/// A mark is said by the one run that holds its lock: the mark file's own
/// lock (`Opened`), which a run takes before it claims the mark and holds
/// until it is done with the file. A run that finds the lock held says
/// nothing of the mark: the run that holds it says it. The claim is a rename
/// of the mark to `<mark>.<pid>-<start>.claim`, with this run's pid and
/// start, and the kernel lets one run make it: a run that finds the mark gone
/// says nothing of it. The claiming run writes the line, then removes the
/// claim. A claim whose run is gone, one whose line advisory.log did not take
/// or one killed before its line, is claimed again and said.
///
/// Once is kept by what stays on disk after the line, not by the run that
/// wrote it, which is gone by the time another run reads the file. A file
/// that stays after its line was written gets the record that it was said
/// (`add_record`), and no run says a file with that record: a claim whose
/// removal failed, and a mark no run can claim (a `judging/` that takes no
/// change). Such a mark is said by the run that holds its lock, with what the
/// rename returned, and that run adds the record before it lets the lock go,
/// so a run that takes the lock after it reads the record. Appending needs no
/// change to `judging/`, which is what the removal or the claim did not get.
/// The first run that can claim such a file removes it and says nothing.
///
/// A mark is said more than once in three cases, and in none is it left
/// unsaid. Where the record cannot be added, advisory.log says so, and a
/// later run says the mark again. A run killed between its line and the
/// removal or the record leaves the mark to a later run, which says it again.
/// A run that can neither lock nor claim a mark says it, and its line says
/// that it could not lock the mark, so another run may say it too.
pub fn report_gone(home: &Path) {
    let dir = dir(home);
    let me = std::process::id();
    // A run whose own start the kernel does not give cannot name a claim. It
    // writes no mark of its own either, and says so (`Mark::open`).
    let Some(my_start) = process::start(me) else { return };
    let listing = match std::fs::read_dir(&dir) {
        Ok(listing) => listing,
        // No directory, or a file in its place (ENOTDIR, 20 on macOS and on
        // Linux): no mark is in it.
        Err(error) if error.kind() == ErrorKind::NotFound || error.raw_os_error() == Some(20) => return,
        Err(error) => return unlisted(home, &dir, error),
    };
    let mut names = Vec::new();
    for entry in listing {
        match entry {
            Ok(entry) if entry.file_type().is_ok_and(|kind| kind.is_file()) => names.push(entry.file_name()),
            Ok(_) => {}
            Err(error) => return unlisted(home, &dir, error),
        }
    }
    names.sort();
    for name in names {
        let path = dir.join(&name);
        if let Some((pid, start)) = mark_name(name.as_bytes()) {
            if let Holder::Gone(fact) = process::holder(pid, start) { claim(home, &path, (pid, start), &fact, (me, my_start)) }
        } else if let Some(((pid, start), (by, by_start))) = claim_name(name.as_bytes()) {
            // Whether a run that is gone said the mark it claimed is not
            // known, so this run says it.
            if !matches!(process::holder(by, by_start), Holder::Gone(_)) { continue }
            if let Holder::Gone(fact) = process::holder(pid, start) { claim(home, &path, (pid, start), &fact, (me, my_start)) }
        }
    }
}

/// A listing of `judging/` that did not finish: the marks in it are not known,
/// and none is reported.
fn unlisted(home: &Path, dir: &Path, error: std::io::Error) {
    state::log_advisory(home, &cat(&[b"post-verify: the judgment marks in ", sh::bytes(dir), b" were not read: ",
        &Outcome::Io(Err(error)).describe(Action::Walk(dir), Form::Action)]));
}

/// A file in `judging/` that a run opened in order to say it, with the file's
/// own lock: an exclusive `flock(2)` on the open file (`File::try_lock`),
/// never waited for. The kernel lets it go when the open file is closed: when
/// this is dropped, or when the run ends, a kill included. The run that holds
/// it is the one run that says the file, whether the rename that claims it
/// takes or not, and it holds it until after its line and the record that it
/// was said (`claim`).
struct Opened {
    /// The file's bytes, from one read through the open file, or what the open
    /// or the read returned.
    read: Result<Vec<u8>, Vec<u8>>,
    /// Empty where this run holds the lock; otherwise the sentence that it
    /// could not lock the file, so another run may say it too.
    unlocked: Vec<u8>,
    /// The open file, whose lock goes with it.
    file: Option<File>,
}

impl Opened {
    /// Opens the file at `path` to read it, takes its lock and reads it. None
    /// where the file is gone, because another run claimed it, and where another
    /// run holds its lock, because that run says it. A file this run cannot open
    /// to read cannot be locked either, and what the open returned is said in
    /// place of its bytes and of the lock.
    fn take(path: &Path) -> Option<Self> {
        let mut file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == ErrorKind::NotFound => return None,
            Err(error) => {
                let unread = Outcome::Io(Err(error)).describe(Action::Read(path), Form::Action);
                return Some(Opened { unlocked: unlocked(&unread), read: Err(unread), file: None })
            }
        };
        let unlocked = locked(file.try_lock(), path)?;
        let mut bytes = Vec::new();
        let read = file.read_to_end(&mut bytes).map(|_| bytes)
            .map_err(|error| Outcome::Io(Err(error)).describe(Action::Read(path), Form::Action));
        Some(Opened { read, unlocked, file: Some(file) })
    }
}

/// What `File::try_lock` returned for the file at `path`, as `Opened` keeps
/// it: none where another run holds the lock, nothing to say where this run
/// took it, and the sentence that it could not lock the file where the lock
/// returned an error.
fn locked(tried: Result<(), TryLockError>, path: &Path) -> Option<Vec<u8>> {
    match tried {
        Ok(()) => Some(Vec::new()),
        Err(TryLockError::WouldBlock) => None,
        Err(TryLockError::Error(error)) => Some(unlocked(&Outcome::Io(Err(error)).describe(Action::Lock(path), Form::Action))),
    }
}

/// The sentence of a line whose file this run could not lock, after the one
/// that it could not claim it: what the open or the lock returned.
fn unlocked(returned: &[u8]) -> Vec<u8> { cat(&[b" It could not lock it either: ", returned, b", so another run may say it too."]) }

/// Claims, at `from` (the mark, or a claim whose run is gone), the mark of the
/// run `owner`, which is gone as `fact` says, and says it (`report_gone`).
fn claim(home: &Path, from: &Path, owner: (u32, u64), fact: &[u8], (me, my_start): (u32, u64)) {
    let mark = dir(home).join(format!("{}-{}.json", owner.0, owner.1));
    let held = dir(home).join(format!("{}-{}.json.{}-{}.claim", owner.0, owner.1, me, my_start));
    // The lock comes before the claim. `_lock` holds it until this run
    // returns, after its line and the record that it was said.
    let Some(Opened { read, unlocked, file: _lock }) = Opened::take(from) else { return };
    match std::fs::rename(from, &held) {
        Ok(()) => {}
        // Another run claimed it after this run opened it, and that run says it.
        Err(error) if error.kind() == ErrorKind::NotFound => return,
        Err(error) => {
            // No run can claim it, so the lock alone keeps it said once. A run
            // that could not take the lock either says so in the line.
            let unclaimed = cat(&[b" This run could not claim the mark: ", &Outcome::Io(Err(error)).describe(Action::RenameOf(from), Form::Action),
                b".", &unlocked]);
            let Some(line) = said(read, &mark, owner, fact, &unclaimed) else { return };
            // The file stays where it is, so the record that it was said goes
            // into it while this run holds the lock, and the runs after this
            // one do not say it again.
            if state::log_advisory(home, &line).success() { add_said(home, from) }
            return
        }
    }
    let Some(line) = said(read, &mark, owner, fact, b"") else { return retire(home, &held, false) };
    // A line advisory.log did not take leaves the claim, and a run after this
    // one is gone claims it again.
    if !state::log_advisory(home, &line).success() { return }
    retire(home, &held, true)
}

/// Adds to a file whose NOT JUDGED line was written, and which stays, the
/// record that it was said. A record that cannot be added is said in
/// advisory.log, because a later run says the mark again.
fn add_said(home: &Path, path: &Path) {
    let added = add_record(path, Added::Said);
    if added.success() { return }
    state::log_advisory(home, &cat(&[b"post-verify: the judgment mark ", sh::bytes(path), b" was said, and the record that it was said was not added to it: ",
        &added.describe(Action::WriteOf(path), Form::Action), b". A later run says it again."]));
}

/// Removes this run's claim, once its line is written (`said`) or once it
/// found that no line is owed. A claim that stays is said in advisory.log.
/// One whose line was written also gets the record that it was said, so the
/// run that claims it again after this one is gone removes it and says
/// nothing; a record that cannot be added is said in the same line, and that
/// run says the mark again.
fn retire(home: &Path, held: &Path, said: bool) {
    let Err(error) = std::fs::remove_file(held) else { return };
    let added = if said { add_record(held, Added::Said) } else { Outcome::Io(Ok(())) };
    let unadded = if added.success() { Vec::new() }
        else { cat(&[b". The record that it was said was not added to it either: ", &added.describe(Action::WriteOf(held), Form::Action)]) };
    state::log_advisory(home, &cat(&[b"post-verify: the claimed judgment mark ", sh::bytes(held), b" was not removed: ",
        &Outcome::Io(Err(error)).describe(Action::Removal, Form::Action), &unadded]));
}

/// The NOT JUDGED line for the mark of the run `owner`, from the one `read`
/// of its file (`Opened::read`): the call the mark names, or, where it does
/// not name its call, what is wrong with it. None for a file with the record
/// that its line was written, whatever its own bytes are, and for a mark with
/// the record that its judgment returned (`Mark::close`), whose run said
/// itself why the mark stayed. `unclaimed` is empty, or the sentences that
/// this run could not claim it, and could not lock it either.
fn said(read: Result<Vec<u8>, Vec<u8>>, mark: &Path, owner: (u32, u64), fact: &[u8], unclaimed: &[u8]) -> Option<Vec<u8>> {
    let head = cat(&[b"its judgment mark ", sh::bytes(mark), b" is still there, and ", fact, b".", unclaimed]);
    let unnamed = |reason: &[u8]| Some(cat(&[b"post-verify NOT JUDGED: a post run did not finish judging a call: ", &head,
        b" The mark ", reason, b", so the call is not known."]));
    let bytes = match read {
        Ok(bytes) => bytes,
        Err(unread) => return unnamed(&cat(&[b"could not be read: ", &unread])),
    };
    let (own, added) = split_records(&bytes);
    if added.contains(&Added::Said) { return None }
    let read = jv::read(own);
    let ([value @ Value::Obj(_)], false) = (read.values.as_slice(), read.failed) else { return unnamed(b"is not one JSON object") };
    let text = |key: &str| jv::field(value, key).ok().and_then(jv::text);
    if text("pid") != Some(owner.0.to_string().as_bytes()) || text("start") != Some(owner.1.to_string().as_bytes()) {
        return unnamed(b"does not name the pid and start in its file name")
    }
    let mut named = Vec::new();
    for key in ["opened_at", "project", "command"] {
        let Some(field) = text(key) else { return unnamed(&cat(&[b"has no string field ", key.as_bytes()])) };
        named.push(field);
    }
    let tool = match jv::field(value, "tool_use_id") {
        Ok(Value::Null) => b"none".as_slice(),
        Ok(Value::Str(id)) => id.as_slice(),
        _ => return unnamed(b"has no string field tool_use_id"),
    };
    if added.contains(&Added::Returned) { return None }
    Some(cat(&[b"post-verify NOT JUDGED: the post run that took this call at ", named[0], b" did not finish judging it: ", &head,
        b" Tool use: ", tool, b". Project: ", named[1], b". Command: ", named[2]]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn the_names_of_marks_and_claims_are_the_ones_open_and_claim_write() {
        assert_eq!(mark_name(b"123-456.json"), Some((123, 456)));
        for name in [&b"0-5.json"[..], b"0123-5.json", b"123-0.json", b"123-05.json", b"+5-6.json", b"2147483648-5.json", b"123-456",
            b"123-456.json.tmp", b".123-456.json.0a1b2c", b"123-456.json.7-8.claim", b"-5.json", b"5-.json", b"5-6-7.json", b"5--6.json"] {
            assert_eq!(mark_name(name), None, "{}", String::from_utf8_lossy(name));
        }
        assert_eq!(claim_name(b"123-456.json.7-8.claim"), Some(((123, 456), (7, 8))));
        for name in [&b"123-456.json.claim"[..], b"123-456.json.7-08.claim", b"123-456.7-8.claim", b"123-456.json.7-8", b"0-456.json.7-8.claim",
            b"123-456.json.0-8.claim"] {
            assert_eq!(claim_name(name), None, "{}", String::from_utf8_lossy(name));
        }
    }

    /// The one read of the file at `path`, as a run that holds its lock reads
    /// it.
    fn read(path: &Path) -> Result<Vec<u8>, Vec<u8>> { Opened::take(path).expect("a file whose lock no run holds").read }

    /// The lock a run takes on a file it says (`Opened`) is held by one open
    /// file at a time, so a run that opens the file while another holds it
    /// says nothing of it, and it goes with the open file that held it. A lock
    /// that returned an error is the sentence that the run could not lock the
    /// file. A file that is gone is not opened.
    #[test]
    fn a_file_in_judging_is_said_by_the_one_run_that_holds_its_lock() {
        let home = crate::os::scratch_dir("safedeps-mark").unwrap();
        std::fs::create_dir(dir(&home)).unwrap();
        let mark = dir(&home).join("7-8.json");
        std::fs::write(&mark, b"{}").unwrap();
        let first = Opened::take(&mark).expect("the lock");
        assert_eq!((first.read.as_deref().ok(), first.unlocked.as_slice()), (Some(&b"{}"[..]), &b""[..]));
        assert!(Opened::take(&mark).is_none(), "a second open file finds the lock held");
        drop(first);
        let second = Opened::take(&mark).expect("the lock went with the open file that held it");
        assert!(second.unlocked.is_empty());
        drop(second);
        let m = mark.display();
        assert_eq!(locked(Err(TryLockError::Error(std::io::Error::from_raw_os_error(45))), &mark).map(|s| String::from_utf8_lossy(&s).into_owned()),
            Some(format!(" It could not lock it either: the lock of {m} returned OS error 45, so another run may say it too.")));
        assert_eq!(locked(Err(TryLockError::WouldBlock), &mark), None);
        assert_eq!(locked(Ok(()), &mark), Some(Vec::new()));
        std::fs::remove_file(&mark).unwrap();
        assert!(Opened::take(&mark).is_none(), "a file that is gone was claimed by another run");
        std::fs::remove_dir_all(&home).unwrap();
    }

    /// The line `said` gives for one read of a mark: the call it names, with
    /// `none` for a null tool use; nothing for a mark with the record that its
    /// judgment returned, nor for a file with the record that it was said,
    /// whatever its own bytes; and what is wrong with a mark it cannot read or
    /// that holds a second object that is not one of those records.
    #[test]
    fn a_mark_is_said_from_one_read_of_it() {
        let home = crate::os::scratch_dir("safedeps-mark").unwrap();
        std::fs::create_dir(dir(&home)).unwrap();
        let mark = dir(&home).join("7-8.json");
        let m = mark.display();
        let object = b"{\"pid\":\"7\",\"start\":\"8\",\"opened_at\":\"2026-11-20T01:02:03Z\",\"tool_use_id\":null,\"project\":\"/p\",\"command\":\"npm ci\"}\n";
        std::fs::write(&mark, object).unwrap();
        let line = said(read(&mark), &mark, (7, 8), b"pid 7 is not running", b"").expect("a line");
        assert_eq!(String::from_utf8_lossy(&line), format!("post-verify NOT JUDGED: the post run that took this call at 2026-11-20T01:02:03Z \
            did not finish judging it: its judgment mark {m} is still there, and pid 7 is not running. Tool use: none. Project: /p. Command: npm ci"));
        std::fs::write(&mark, cat(&[object, b"{\"returned_at\":\"2026-11-20T01:02:04Z\"}\n"])).unwrap();
        assert_eq!(said(read(&mark), &mark, (7, 8), b"pid 7 is not running", b""), None, "a judgment that returned is not reported");
        std::fs::write(&mark, cat(&[object, b"{\"returned_at\":4}\n"])).unwrap();
        let line = said(read(&mark), &mark, (7, 8), b"pid 7 is not running", b"").expect("a line");
        assert_eq!(String::from_utf8_lossy(&line), format!("post-verify NOT JUDGED: a post run did not finish judging a call: its judgment mark {m} \
            is still there, and pid 7 is not running. The mark is not one JSON object, so the call is not known."));
        let said_at = b"\n{\"said_at\":\"2026-11-20T01:02:05Z\"}\n";
        for own in [&object[..], b"{\"pid\":\"", b"", &cat(&[object, b"\n{\"returned_at\":\"2026-11-20T01:02:04Z\"}\n"])] {
            std::fs::write(&mark, cat(&[own, said_at])).unwrap();
            assert_eq!(said(read(&mark), &mark, (7, 8), b"pid 7 is not running", b""), None, "said once: {:?}", String::from_utf8_lossy(own));
        }
        std::fs::write(&mark, b"{\"said_at\":\"2026-11-20T01:02:05Z\"}").unwrap();
        let line = said(read(&mark), &mark, (7, 8), b"pid 7 is not running", b"").expect("a record starts a line, so this is the mark's own bytes");
        assert_eq!(String::from_utf8_lossy(&line), format!("post-verify NOT JUDGED: a post run did not finish judging a call: its judgment mark {m} \
            is still there, and pid 7 is not running. The mark does not name the pid and start in its file name, so the call is not known."));
        std::fs::set_permissions(&mark, std::fs::Permissions::from_mode(0o000)).unwrap();
        let line = said(read(&mark), &mark, (7, 8), b"pid 7 is not running", b"").expect("a line");
        assert_eq!(String::from_utf8_lossy(&line), format!("post-verify NOT JUDGED: a post run did not finish judging a call: its judgment mark {m} \
            is still there, and pid 7 is not running. The mark could not be read: the read of {m} returned OS error 13, so the call is not known."));
        std::fs::remove_dir_all(&home).unwrap();
    }

    /// A claim whose line was written and which cannot be removed gets the
    /// record that it was said, and advisory.log says it stayed. The run that
    /// takes it up after its claimer is gone says nothing of it, whether it
    /// can claim it again or not, and the first run that can claim it removes
    /// it.
    #[test]
    fn a_claim_that_stays_after_its_line_is_not_said_again() {
        let home = crate::os::scratch_dir("safedeps-mark").unwrap();
        std::fs::create_dir(dir(&home)).unwrap();
        let me = std::process::id();
        let start = process::start(me).expect("the kernel's start of this process");
        // The mark's run and the run that claimed it: this pid, with starts
        // the kernel did not store for it, so both are gone.
        let held = dir(&home).join(format!("{me}-{}.json.{me}-{}.claim", start + 1, start + 2));
        let object = jv::dump(&jv::obj(vec![("pid", jv::s(me.to_string().as_bytes())), ("start", jv::s((start + 1).to_string().as_bytes())),
            ("opened_at", jv::s(b"2026-11-20T01:02:03Z")), ("tool_use_id", Value::Null), ("project", jv::s(b"/p")), ("command", jv::s(b"npm ci"))]));
        std::fs::write(&held, &object).unwrap();
        std::fs::set_permissions(dir(&home), std::fs::Permissions::from_mode(0o500)).unwrap();
        retire(&home, &held, true);
        let log = std::fs::read(home.join("advisory.log")).unwrap();
        let stayed = cat(&[b"\tpost-verify: the claimed judgment mark ", sh::bytes(&held), b" was not removed: removal returned OS error 13\n"]);
        assert!(log.ends_with(&stayed) && log.iter().filter(|b| **b == b'\n').count() == 1, "{}", String::from_utf8_lossy(&log));
        let bytes = std::fs::read(&held).unwrap();
        assert_eq!(split_records(&bytes), (object.as_slice(), vec![Added::Said]), "{}", String::from_utf8_lossy(&bytes));
        report_gone(&home);
        assert_eq!(std::fs::read(home.join("advisory.log")).unwrap(), log, "a run that cannot claim it again says nothing");
        assert_eq!(std::fs::read(&held).unwrap(), bytes, "and leaves it as it is");
        std::fs::set_permissions(dir(&home), std::fs::Permissions::from_mode(0o700)).unwrap();
        report_gone(&home);
        assert_eq!(std::fs::read(home.join("advisory.log")).unwrap(), log, "a run that claims it again says nothing");
        assert_eq!(std::fs::read_dir(dir(&home)).unwrap().count(), 0, "and removes it");
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn a_mark_names_its_process_and_goes_when_its_judgment_returns() {
        let home = crate::os::scratch_dir("safedeps-mark").unwrap();
        let pid = std::process::id();
        let start = process::start(pid).expect("the kernel's start of this process");
        let mut mark = Mark::open(&home, b"npm install a", Path::new("/project"), Some("toolu_1"));
        let State::Written(path) = &mark.0 else { panic!("a written mark") };
        let path = path.clone();
        assert_eq!(path, dir(&home).join(format!("{}-{}.json", pid, start)));
        let value = jv::read_one_object(&path).expect("one JSON object");
        let text = |key| jv::field(&value, key).ok().and_then(jv::text).map(<[u8]>::to_vec);
        assert_eq!(text("pid"), Some(pid.to_string().into_bytes()));
        assert_eq!(text("start"), Some(start.to_string().into_bytes()));
        assert_eq!(text("command"), Some(b"npm install a".to_vec()));
        assert_eq!(text("project"), Some(b"/project".to_vec()));
        assert_eq!(text("tool_use_id"), Some(b"toolu_1".to_vec()));
        assert!(text("opened_at").is_some_and(|t| t.len() == 20 && t.ends_with(b"Z")));
        assert_eq!(mark.unjudged(), None, "a written mark lets the judgment start");
        assert_eq!(mark.unwritten(), None, "a written mark gives the hook's answer no line");
        mark.close(&home, b"npm install a");
        assert!(!sh::present(&path));
        assert!(!sh::present(&home.join("advisory.log")), "a mark that went says nothing");
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn a_mark_that_cannot_be_written_is_said_and_stops_nothing() {
        let home = crate::os::scratch_dir("safedeps-mark").unwrap();
        std::fs::write(dir(&home), b"").unwrap();
        let mut mark = Mark::open(&home, b"npm install b", Path::new("/project"), None);
        assert!(matches!(mark.0, State::Logged(_)));
        let log = std::fs::read(home.join("advisory.log")).unwrap();
        let said = cat(&[b"\tpost-verify: this run wrote no judgment mark: the write of ", sh::bytes(&dir(&home)), b"/",
            format!("{}-", std::process::id()).as_bytes()]);
        assert!(log.windows(said.len()).any(|w| w == said.as_slice()), "{}", String::from_utf8_lossy(&log));
        assert!(log.ends_with(b". Command: npm install b\n"));
        assert_eq!(mark.unjudged(), None, "advisory.log took the line, so the judgment starts");
        let answer = mark.unwritten().expect("a line for the hook's answer");
        let head = cat(&[b"safedeps: this run wrote no judgment mark: the write of ", sh::bytes(&dir(&home)), b"/",
            format!("{}-", std::process::id()).as_bytes()]);
        assert!(answer.starts_with(&head), "{}", String::from_utf8_lossy(&answer));
        assert!(answer.ends_with(b". Without that mark, a judgment the runtime kills before it returns leaves no record."));
        assert_eq!(mark.unwritten(), None, "the line is given once");
        mark.close(&home, b"npm install b");
        assert_eq!(std::fs::read(home.join("advisory.log")).unwrap(), log, "no mark, nothing to remove");
        std::fs::remove_dir_all(&home).unwrap();
    }

    /// Decision 6: neither the mark nor the advisory.log line for it is
    /// written, so the run starts no judgment, and the hook's answer is the
    /// report that says so.
    #[test]
    fn a_run_with_neither_mark_nor_log_line_starts_no_judgment() {
        let home = crate::os::scratch_dir("safedeps-mark").unwrap();
        std::fs::create_dir(dir(&home)).unwrap();
        std::fs::set_permissions(dir(&home), std::fs::Permissions::from_mode(0o500)).unwrap();
        std::fs::create_dir(home.join("advisory.log")).unwrap();
        let pid = std::process::id();
        let start = process::start(pid).expect("the kernel's start of this process");
        let mut mark = Mark::open(&home, b"npm install c", Path::new("/project"), None);
        assert_eq!(mark.unwritten(), None, "no paragraph for an answer the judgment gives");
        let report = mark.unjudged().expect("the hook's answer in place of a judgment");
        let expected = cat(&[b"safedeps: this install was not judged.\n\nThis run wrote no judgment mark: the write of ",
            sh::bytes(&dir(&home)), format!("/{}-{}.json", pid, start).as_bytes(), b" returned OS error 13.\n",
            b"It wrote no line to advisory.log either: the write of ", sh::bytes(&home), b"/advisory.log returned OS error 21.\n",
            b"With neither, a judgment the runtime killed would leave no record, so this run did not start one.\n",
            b"No closure check ran, and nothing was rolled back.\nCommand: npm install c\nProject: /project"]);
        assert_eq!(String::from_utf8_lossy(&report), String::from_utf8_lossy(&expected));
        assert_eq!(mark.unjudged(), None, "the answer is given once");
        mark.close(&home, b"npm install c");
        assert_eq!(std::fs::read_dir(dir(&home)).unwrap().count(), 0, "no mark and no temporary file");
        assert!(home.join("advisory.log").is_dir());
        std::fs::set_permissions(dir(&home), std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::remove_dir_all(&home).unwrap();
    }
}
