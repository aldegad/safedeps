//! Which lockfile npm reads in a project, and npm's two records there, each
//! read once.
//!
//! npm reads npm-shrinkwrap.json and package-lock.json in the project
//! directory, and uses the shrinkwrap where it holds a byte, else
//! package-lock.json where it holds a byte, else neither (@npmcli/arborist,
//! `Shrinkwrap.load`: `data = sw || lock || '{}'`). A file that is not there
//! holds no byte. A read of either that fails stops npm's load, and here it
//! is a record that could not be read: a directory, a FIFO and a read that
//! fails. The installed tree's record is node_modules/.package-lock.json.
//!
//! A link that does not resolve is the one place this is stricter than npm.
//! npm's read of it fails with ENOENT, which npm takes for no file. A link
//! that loops fails with ELOOP, which stops npm's load. The shell cannot tell
//! the two apart by testing the path, so both implementations read either
//! one as a record that could not be read.
//!
//! The post hook reads the two records once, here, and every judgment of an
//! install takes those bytes: the closure (`effect::check`), the accepted
//! sources (`accepted::Sources`), what the install brought (`Npm::collect`),
//! the bytes it records as withheld (`Npm::record`) and the tree a rebuild
//! runs over (`tree::judge`). None of them opens a record again, so the
//! check and the use act on one read, and a package-lock.json npm does not
//! read is judged by none of them.
//!
//! The shell's watch and audit choose with `safedeps_npm_project_lockfile`
//! (lib/npm/closure.sh), and `choice_matches_cli` holds the two to one
//! answer.
use super::{jv, report::cat, sh, snapshot::Store};
use crate::callid::record as rec;
use std::{fs, io::{self, Read}, os::unix::fs::OpenOptionsExt, path::Path};
type W = Vec<u8>;

/// One npm record as it was read.
pub struct Record {
    pub rel: &'static str,
    pub bytes: W,
    pub stream: jv::Stream,
}

impl Record {
    fn new(rel: &'static str, bytes: W) -> Self {
        let stream = jv::read(&bytes);
        Record { rel, bytes, stream }
    }
}

/// What one path holds: nothing, its bytes, or why they could not be read.
enum Held {
    Absent,
    Bytes(W),
    Unread(W),
}

/// The bytes at `path`. A FIFO is opened without waiting for a writer and is
/// never read.
fn held(path: &Path) -> Held {
    let opened = fs::OpenOptions::new().read(true).custom_flags(crate::os::O_NONBLOCK).open(path);
    let mut f = match opened {
        Ok(f) => f,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return if fs::symlink_metadata(path).is_ok() { Held::Unread(b"it is a link that does not resolve".to_vec()) } else { Held::Absent }
        }
        Err(e) => return Held::Unread(e.to_string().into_bytes()),
    };
    match f.metadata() {
        Ok(m) if m.is_file() => {}
        Ok(_) => return Held::Unread(b"it is not a regular file".to_vec()),
        Err(e) => return Held::Unread(e.to_string().into_bytes()),
    }
    let mut bytes = Vec::new();
    match f.read_to_end(&mut bytes) {
        Ok(_) => Held::Bytes(bytes),
        Err(e) => Held::Unread(e.to_string().into_bytes()),
    }
}

/// A record that is there and could not be read.
#[derive(Clone, Debug, PartialEq)]
pub struct Unread {
    pub rel: &'static str,
    pub why: W,
}

impl Unread {
    pub fn text(&self, project: &Path) -> W {
        cat(&[sh::bytes(project), b"/", self.rel.as_bytes(), b" could not be read (", &self.why, b")"])
    }
}

/// npm's choice between the two lockfiles, from what each path holds, in
/// `rec::LOCKFILES` order: the first that holds a byte. One that could not
/// be read stops the choice, as it stops npm's load.
fn choose(files: Vec<(&'static str, Held)>) -> Result<Option<Record>, Unread> {
    let mut chosen = None;
    for (rel, held) in files {
        match held {
            Held::Absent => {}
            Held::Unread(why) => return Err(Unread { rel, why }),
            Held::Bytes(b) => if chosen.is_none() && !b.is_empty() { chosen = Some(Record::new(rel, b)) },
        }
    }
    Ok(chosen)
}

/// The lockfile npm reads in `dir`: Ok(None) where neither holds a byte.
pub fn chosen(dir: &Path) -> Result<Option<Record>, Unread> {
    choose(rec::LOCKFILES.iter().map(|rel| (*rel, held(&dir.join(rel)))).collect())
}

/// npm's two records in a project, as the post hook judges them.
#[derive(Default)]
pub struct Records {
    /// The lockfile npm reads, where one holds a byte.
    pub lock: Option<Record>,
    /// The installed tree's record, where it is there.
    pub tree: Option<Record>,
    /// A record that could not be read. Nothing is judged as read beside it:
    /// whoever reads the records answers for this one first. The effect gate
    /// rolls the install back for it (`effect::check`). The record of withheld
    /// bytes, which only adds a restriction, says in advisory.log that the
    /// bytes only this record names were not recorded, and records the bytes
    /// the records read beside it name (`Npm::record`).
    pub unread: Option<Unread>,
}

impl Records {
    pub fn read(project: &Path) -> Self {
        let mut out = Records::default();
        match chosen(project) {
            Ok(lock) => out.lock = lock,
            Err(why) => out.unread = Some(why),
        }
        match held(&project.join(rec::HIDDEN)) {
            Held::Absent => {}
            Held::Bytes(b) => out.tree = Some(Record::new(rec::HIDDEN, b)),
            Held::Unread(why) => { out.unread.get_or_insert(Unread { rel: rec::HIDDEN, why }); }
        }
        out
    }

    /// The records read, the lockfile first.
    pub fn each(&self) -> impl Iterator<Item = &Record> {
        self.lock.iter().chain(self.tree.iter())
    }
}

/// The lockfile npm read before the command, chosen the same way from the
/// copies the pre-command snapshot keeps (`snapshot::LOCKS`). A lockfile the
/// snapshot records as absent (`.missing`) holds no byte, and so does one it
/// does not record at all: a snapshot an older pre-guard took kept no
/// shrinkwrap. A copy that cannot be read is Err, as a record is.
pub fn earlier(store: &Store) -> Result<Option<Record>, Unread> {
    choose(rec::LOCKFILES.iter().map(|rel| (*rel, held(&store.path(&store.id, rel.as_bytes())))).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Dir(std::path::PathBuf);
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    // The watch and the audit choose with safedeps_npm_project_lockfile, and
    // the hook with `chosen`. Every shape of the two files, chosen by both:
    // the file each names, or that the choice could not be made.
    #[test]
    fn choice_matches_cli() {
        let root = Dir(crate::os::scratch_dir("safedeps-lockfile-choice").unwrap());
        let shapes: &[(&str, &[(&str, Option<&str>)])] = &[
            ("neither", &[]),
            ("shrinkwrap", &[("npm-shrinkwrap.json", Some("{\"a\":1}"))]),
            ("lock", &[("package-lock.json", Some("{\"a\":1}"))]),
            ("both", &[("npm-shrinkwrap.json", Some("{\"a\":1}")), ("package-lock.json", Some("{\"b\":1}"))]),
            ("empty-shrinkwrap", &[("npm-shrinkwrap.json", Some("")), ("package-lock.json", Some("{\"b\":1}"))]),
            ("empty-lock", &[("npm-shrinkwrap.json", Some("{\"a\":1}")), ("package-lock.json", Some(""))]),
            ("both-empty", &[("npm-shrinkwrap.json", Some("")), ("package-lock.json", Some(""))]),
            ("lone-empty", &[("package-lock.json", Some(""))]),
            ("blank-shrinkwrap", &[("npm-shrinkwrap.json", Some(" \n")), ("package-lock.json", Some("{\"b\":1}"))]),
            ("broken-shrinkwrap", &[("npm-shrinkwrap.json", Some("{broken")), ("package-lock.json", Some("{\"b\":1}"))]),
            ("dir-shrinkwrap", &[("npm-shrinkwrap.json", None), ("package-lock.json", Some("{\"b\":1}"))]),
            ("dir-lock", &[("npm-shrinkwrap.json", Some("{\"a\":1}")), ("package-lock.json", None)]),
            ("dangling-shrinkwrap", &[("package-lock.json", Some("{\"b\":1}"))]),
            ("linked-lock", &[("package-lock.json", Some("{\"b\":1}"))]),
        ];
        let mut dirs = Vec::new();
        for (name, files) in shapes {
            let dir = root.0.join(name);
            fs::create_dir_all(&dir).unwrap();
            for (file, body) in *files {
                match body {
                    Some(b) => fs::write(dir.join(file), b).unwrap(),
                    None => fs::create_dir(dir.join(file)).unwrap(),
                }
            }
            if *name == "dangling-shrinkwrap" {
                std::os::unix::fs::symlink("nowhere.json", dir.join("npm-shrinkwrap.json")).unwrap();
            }
            if *name == "linked-lock" {
                fs::rename(dir.join("package-lock.json"), dir.join("real.json")).unwrap();
                std::os::unix::fs::symlink("real.json", dir.join("package-lock.json")).unwrap();
            }
            dirs.push(dir);
        }
        let core: Vec<String> = dirs.iter().map(|d| match chosen(d) {
            Ok(Some(r)) => format!("chose {}", r.rel),
            Ok(None) => "none".to_owned(),
            Err(u) => format!("unread {}", u.rel),
        }).collect();
        let script = "source lib/npm/closure.sh\nfor d in \"$@\"; do\n  rc=0; name=$(safedeps_npm_project_lockfile \"$d\" \"$d.copy\") || rc=$?\n  case \"$rc:$name\" in 0:) echo none ;; 0:*) echo \"chose $name\" ;; 1:*) echo \"unread $name\" ;; *) echo \"rc $rc\" ;; esac\ndone";
        let out = std::process::Command::new("/bin/bash").current_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/.."))
            .env_clear().env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .arg("-c").arg(script).arg("choice-contract").args(&dirs).output().unwrap();
        assert!(out.status.success(), "the shell's choice: {}", String::from_utf8_lossy(&out.stderr));
        let cli: Vec<String> = String::from_utf8(out.stdout).unwrap().lines().map(str::to_owned).collect();
        assert_eq!(core, cli, "the core and the shell choose the same lockfile, for {:?}", shapes.iter().map(|s| s.0).collect::<Vec<_>>());
        // What npm reads, as the arborist reads it: the shrinkwrap with a
        // byte, else the lockfile with one, and a file it cannot read stops
        // it. The dangling shrinkwrap is the one answer stricter than npm's,
        // which reads package-lock.json there (see the module comment).
        let want = ["none", "chose npm-shrinkwrap.json", "chose package-lock.json", "chose npm-shrinkwrap.json", "chose package-lock.json",
            "chose npm-shrinkwrap.json", "none", "none", "chose npm-shrinkwrap.json", "chose npm-shrinkwrap.json",
            "unread npm-shrinkwrap.json", "unread package-lock.json", "unread npm-shrinkwrap.json", "chose package-lock.json"];
        assert_eq!(core, want, "the choice is npm's");
        // The copy the shell judges holds the chosen file's bytes.
        assert_eq!(fs::read(root.0.join("both.copy")).unwrap(), b"{\"a\":1}");
        assert_eq!(fs::read(root.0.join("empty-shrinkwrap.copy")).unwrap(), b"{\"b\":1}");
    }
}
