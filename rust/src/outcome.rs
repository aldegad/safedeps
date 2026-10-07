//! Observed operation results and the one vocabulary used to report them.
//! A process signal, a failed start and a failed wait are never exit codes.
use std::{io, os::unix::process::ExitStatusExt, process::ExitStatus};

#[derive(Debug)]
pub enum Outcome {
    Finished(ExitStatus),
    StartFailure(io::Error),
    StatusFailure(io::Error),
    Deadline,
    Io(io::Result<()>),
}

#[derive(Clone, Copy)]
pub enum Form { Action, Detail, Judgment, Within(u64) }

impl Outcome {
    pub fn status(status: ExitStatus) -> Self { Self::Finished(status) }
    pub fn success(&self) -> bool {
        match self { Self::Finished(status)=>status.success(), Self::Io(Ok(()))=>true, _=>false }
    }

    pub fn describe(&self, action: &[u8], form: Form) -> Vec<u8> {
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
            assert_eq!(outcome.describe(b"npm rebuild",Form::Action),line.as_bytes());
        }
        assert_eq!(Outcome::status(ExitStatus::from_raw(0x7f)).describe(b"",Form::Judgment),b"no exit code or signal");
        assert_eq!(Outcome::status(ExitStatus::from_raw(9)).describe(b"",Form::Detail),b"signal 9");
        assert_eq!(Outcome::Deadline.describe(b"the walk of fixture",Form::Within(5)),b"the walk of fixture did not finish within 5s");
        assert!(Outcome::status(ExitStatus::from_raw(0)).success());
    }
}
