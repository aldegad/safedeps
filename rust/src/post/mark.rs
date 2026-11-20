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

/// This run's mark: the path it wrote, or none where it wrote none.
pub struct Mark {
    path: Option<PathBuf>,
    /// Where no mark was written, the line the hook's answer gives for it.
    unwritten: Option<Vec<u8>>,
}

impl Mark {
    /// Writes this run's mark for a call it is taking. The caller removes the
    /// call's own records only after this returns, so a kill at any point
    /// leaves at least one of the two on disk. A mark is written whole, through a
    /// temporary name and a rename, so a mark is never read half written; the
    /// temporary file starts with a dot. A mark that cannot be written stops
    /// nothing: the judgment goes on, and the fact is said in advisory.log and
    /// in the hook's answer (`not_written`).
    pub fn open(home: &Path, command: &[u8], project: &Path, tool_use_id: Option<&str>) -> Self {
        let pid = std::process::id();
        let pid_text = pid.to_string();
        let Some(start) = process::start(pid) else {
            let unstarted = cat(&[b"this run wrote no judgment mark: the native process query gave no start for pid ", pid_text.as_bytes()]);
            state::log_advisory(home, &cat(&[b"post-verify: ", &unstarted, b". Command: ", command]));
            return Self::not_written(&unstarted)
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
            Ok(()) => Self { path: Some(path), unwritten: None },
            Err(error) => {
                let unwritable = cat(&[b"this run wrote no judgment mark: ", &Outcome::Io(Err(error)).describe(Action::Write(path.as_path()), Form::Action)]);
                state::log_advisory(home, &cat(&[b"post-verify: ", &unwritable, b". Command: ", command]));
                Self::not_written(&unwritable)
            }
        }
    }

    /// A run whose mark was not written. The fact goes to advisory.log, where
    /// the caller wrote it, and to the hook's answer, and neither stands in
    /// for the other. The log line is written at once, so it outlives a later
    /// kill of this run. The answer is printed when the run returns, and it is
    /// there because `state::log_advisory` drops a line it cannot append.
    fn not_written(fact: &[u8]) -> Self {
        Self { path: None, unwritten: Some(cat(&[b"safedeps: ", fact, b". ", UNMARKED])) }
    }

    /// The line the hook's answer gives for this run's mark: one where the
    /// mark was not written, none where it was. `run::main` puts it last in
    /// the answer, after the judgment's own message.
    pub fn unwritten(&mut self) -> Option<Vec<u8>> { self.unwritten.take() }

    /// Removes this run's mark once its judgment returned, whatever it
    /// returned. A mark that cannot be removed is said in advisory.log, beside
    /// the judgment's own lines, because a later report of it would otherwise
    /// stand alone.
    pub fn close(&mut self, home: &Path, command: &[u8]) {
        let Some(path) = self.path.take() else { return };
        if let Err(error) = std::fs::remove_file(&path) {
            state::log_advisory(home, &cat(&[b"post-verify: the judgment of this call returned, and its judgment mark ", sh::bytes(&path),
                b" was not removed: ", &Outcome::Io(Err(error)).describe(Action::Removal, Form::Action), b". Command: ", command]));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mark_names_its_process_and_goes_when_its_judgment_returns() {
        let home = crate::os::scratch_dir("safedeps-mark").unwrap();
        let pid = std::process::id();
        let start = process::start(pid).expect("the kernel's start of this process");
        let mut mark = Mark::open(&home, b"npm install a", Path::new("/project"), Some("toolu_1"));
        let path = mark.path.clone().expect("a written mark");
        assert_eq!(path, dir(&home).join(format!("{}-{}.json", pid, start)));
        let value = jv::read_one_object(&path).expect("one JSON object");
        let text = |key| jv::field(&value, key).ok().and_then(jv::text).map(<[u8]>::to_vec);
        assert_eq!(text("pid"), Some(pid.to_string().into_bytes()));
        assert_eq!(text("start"), Some(start.to_string().into_bytes()));
        assert_eq!(text("command"), Some(b"npm install a".to_vec()));
        assert_eq!(text("project"), Some(b"/project".to_vec()));
        assert_eq!(text("tool_use_id"), Some(b"toolu_1".to_vec()));
        assert!(text("opened_at").is_some_and(|t| t.len() == 20 && t.ends_with(b"Z")));
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
        assert!(mark.path.is_none());
        let log = std::fs::read(home.join("advisory.log")).unwrap();
        let said = cat(&[b"\tpost-verify: this run wrote no judgment mark: the write of ", sh::bytes(&dir(&home)), b"/",
            format!("{}-", std::process::id()).as_bytes()]);
        assert!(log.windows(said.len()).any(|w| w == said.as_slice()), "{}", String::from_utf8_lossy(&log));
        assert!(log.ends_with(b". Command: npm install b\n"));
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
}
