//! Observed operation results and the one vocabulary used to report them.
//! A process signal, a failed start and a failed wait are never exit codes.
use std::{io, os::unix::{process::ExitStatusExt, ffi::OsStrExt}, path::Path, process::ExitStatus};

#[derive(Debug)]
pub enum Outcome {
    Finished(ExitStatus),
    StartFailure(io::Error),
    StatusFailure(io::Error),
    Deadline,
    Io(io::Result<()>),
}

// Two phrasings stand for a write and a rename, each pinned by its own rows:
// Write and Rename say "the write to" and "the rename to" a path (an
// approval's commit and the migration); WriteOf and RenameOf say "the write
// of" and "the rename of" a path (a post run's judgment mark). Touch is
// setting a path's modification time. Link is link(2) to a path, the name
// it makes.
#[derive(Clone, Copy)]
pub enum Action<'a> { Npm, NpmConfig, NpmQuery, NpmRebuild, Curl, Judgment, Walk(&'a Path), NativeInspection(&'a Path), Copy, Removal, Gzip, Read(&'a Path), Create(&'a Path), Open(&'a Path), Write(&'a Path), Sync(&'a Path), Rename(&'a Path), Link(&'a Path), Lock(&'a Path), Touch(&'a Path), WriteOf(&'a Path), RenameOf(&'a Path) }

#[derive(Clone, Copy)]
pub enum Form { Action, Detail, Judgment, Within(u64) }

impl Outcome {
    pub fn status(status: ExitStatus) -> Self { Self::Finished(status) }
    pub fn success(&self) -> bool {
        match self { Self::Finished(status)=>status.success(), Self::Io(Ok(()))=>true, _=>false }
    }

    pub fn describe(&self, action: Action<'_>, form: Form) -> Vec<u8> {
        let named;
        let action: &[u8] = match action {
            Action::Npm=>b"npm", Action::NpmConfig=>b"npm config", Action::NpmQuery=>b"npm query",
            Action::NpmRebuild=>b"npm rebuild", Action::Curl=>b"curl", Action::Judgment=>b"judgment",
            Action::Copy=>b"copy", Action::Removal=>b"removal", Action::Gzip=>b"gzip",
            Action::Walk(path)=>{named=[b"the walk of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Read(path)=>{named=[b"the read of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Create(path)=>{named=[b"the creation of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Open(path)=>{named=[b"the open of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Write(path)=>{named=[b"the write to ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Sync(path)=>{named=[b"the sync of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Rename(path)=>{named=[b"the rename to ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Link(path)=>{named=[b"the link to ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Lock(path)=>{named=[b"the lock of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::Touch(path)=>{named=[b"the touch of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::NativeInspection(path)=>{named=[b"native binary inspection of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::WriteOf(path)=>{named=[b"the write of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
            Action::RenameOf(path)=>{named=[b"the rename of ".as_slice(),path.as_os_str().as_bytes()].concat();&named},
        };
        let cat=|parts: &[&[u8]]| parts.concat();
        let error=|error: &io::Error| match error.raw_os_error() {
            Some(code)=>format!("OS error {}",code).into_bytes(),
            None=>b"error without an OS code".to_vec(),
        };
        let detail=matches!(form,Form::Detail|Form::Judgment);
        match self {
            Self::Finished(status) => {
                if let Some(code)=status.code() {
                    if detail { format!("exit {}{}",if matches!(form,Form::Judgment){"code "}else{""},code).into_bytes() }
                    else { cat(&[b"ran ",action,b": exit ",code.to_string().as_bytes()]) }
                } else if let Some(signal)=status.signal() {
                    if detail { format!("signal {}",signal).into_bytes() }
                    else { cat(&[action,b" terminated by signal ",signal.to_string().as_bytes()]) }
                } else if detail { b"no exit code or signal".to_vec() }
                else { cat(&[action,b" ended without an exit code or signal"]) }
            },
            Self::StartFailure(e) => cat(&[b"could not start ",action,b": ",&error(e)]),
            Self::StatusFailure(e) => cat(&[b"could not read ",action,b" process status: ",&error(e)]),
            Self::Deadline => match form {
                Form::Within(seconds)=>cat(&[action,b" did not finish within ",seconds.to_string().as_bytes(),b"s"]),
                _=>cat(&[action,b" did not finish before the deadline"]),
            },
            Self::Io(Ok(())) => cat(&[action,b" returned without error"]),
            Self::Io(Err(e)) if e.raw_os_error().is_none() => cat(&[action,b" returned an error without an OS code"]),
            Self::Io(Err(e)) => cat(&[action,b" returned ",&error(e)]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn file_operations_keep_the_path_and_the_os_error() {
        let path = Path::new(std::ffi::OsStr::from_bytes(b"/fixture/path with spaces-\xff"));
        for (action, name) in [
            (Action::Create(path), b"the creation of ".as_slice()),
            (Action::Open(path), b"the open of "),
            (Action::Read(path), b"the read of "),
            (Action::Write(path), b"the write to "),
            (Action::Sync(path), b"the sync of "),
            (Action::Rename(path), b"the rename to "),
            (Action::Link(path), b"the link to "),
            (Action::Lock(path), b"the lock of "),
            (Action::Touch(path), b"the touch of "),
            (Action::WriteOf(path), b"the write of "),
            (Action::RenameOf(path), b"the rename of "),
        ] {
            assert_eq!(Outcome::Io(Err(io::Error::from_raw_os_error(5))).describe(action, Form::Action),
                [name, path.as_os_str().as_bytes(), b" returned OS error 5"].concat());
            assert_eq!(Outcome::Io(Err(io::Error::other("private text"))).describe(action, Form::Action),
                [name, path.as_os_str().as_bytes(), b" returned an error without an OS code"].concat());
        }
    }
    #[test]
    fn claims_keep_observed_outcomes_distinct() {
        let rows=[
            (Outcome::status(ExitStatus::from_raw(7<<8)),"ran npm rebuild: exit 7"),
            (Outcome::status(ExitStatus::from_raw(9)),"npm rebuild terminated by signal 9"),
            (Outcome::status(ExitStatus::from_raw(0x7f)),"npm rebuild ended without an exit code or signal"),
            (Outcome::StartFailure(io::Error::from_raw_os_error(13)),"could not start npm rebuild: OS error 13"),
            (Outcome::StartFailure(io::Error::other("fixture")),"could not start npm rebuild: error without an OS code"),
            (Outcome::StatusFailure(io::Error::from_raw_os_error(10)),"could not read npm rebuild process status: OS error 10"),
            (Outcome::StatusFailure(io::Error::other("fixture")),"could not read npm rebuild process status: error without an OS code"),
            (Outcome::Deadline,"npm rebuild did not finish before the deadline"),
        ];
        for (outcome,line) in rows {
            assert!(!outcome.success());
            assert_eq!(outcome.describe(Action::NpmRebuild,Form::Action),line.as_bytes());
        }
        assert_eq!(Outcome::status(ExitStatus::from_raw(0x7f)).describe(Action::Judgment,Form::Judgment),b"no exit code or signal");
        assert_eq!(Outcome::status(ExitStatus::from_raw(9)).describe(Action::Npm,Form::Detail),b"signal 9");
        assert_eq!(Outcome::Deadline.describe(Action::Walk(Path::new("fixture")),Form::Within(5)),b"the walk of fixture did not finish within 5s");
        assert_eq!(Outcome::Io(Err(io::Error::from_raw_os_error(45))).describe(Action::Lock(Path::new("fixture")),Form::Action),b"the lock of fixture returned OS error 45");
        assert!(Outcome::status(ExitStatus::from_raw(0)).success());
    }
}
