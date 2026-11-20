//! The judgment mark: one file a post run writes when it takes a call and
//! removes when the judgment of that call returns. A mark that outlives its
//! run is the record of a judgment the run did not finish: the runtime's kill
//! at 30 s, a panic, or any other end the code did not choose. A mark is never
//! a lock, and nothing waits on it.
//!
//! The file is `judging/<pid>-<start>.json` under `SAFEDEPS_HOME`, named by
//! the process that holds it: its pid and the start the kernel stored for it
//! (`process::start`). Two runs alive at once have two names, and a pid the
//! kernel hands out again comes with another start, so no run writes or
//! removes another run's mark. A run removes only the path it wrote.
use super::{jv, process, report::cat, sh};
use crate::{json::Value, os, outcome::{Action, Form, Outcome}, state};
use std::path::{Path, PathBuf};

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
                let unwritable = cat(&[b"this run wrote no judgment mark: ", &Outcome::Io(Err(error)).describe(Action::Write(path.as_path()), Form::Action)]);
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
        let unlogged = logged.describe(Action::Write(state::advisory_path(home).as_path()), Form::Action);
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
    /// the judgment's own lines, because a later report of it would otherwise
    /// stand alone.
    pub fn close(&mut self, home: &Path, command: &[u8]) {
        let State::Written(path) = &self.0 else { return };
        let path = path.clone();
        self.0 = State::Spent;
        if let Err(error) = std::fs::remove_file(&path) {
            state::log_advisory(home, &cat(&[b"post-verify: the judgment of this call returned, and its judgment mark ", sh::bytes(&path),
                b" was not removed: ", &Outcome::Io(Err(error)).describe(Action::Removal, Form::Action), b". Command: ", command]));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

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
