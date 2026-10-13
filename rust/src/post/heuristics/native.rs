//! Bounded identification of image headers, not execution or loader emulation.
//! Selection, baseline reads and candidate I/O all run in the supervised child.
use super::{cat, sh};
use crate::outcome::{Action, Form, Outcome};
use std::{collections::BTreeSet, fs, io::{self, Read}, path::Path, time::{Duration, Instant}};

mod formats;
pub(crate) mod supervise;
#[cfg(test)]
mod tests;

const FILE_BYTES: usize = 64 * 1024;
const TOTAL_BYTES: usize = 20 * FILE_BYTES;
const LIST_BYTES: usize = 1024 * 1024;
const LIST_ENTRIES: usize = 16_384;
const SAMPLE: usize = 20;
const SCAN_TIME: Duration = Duration::from_secs(1);

#[derive(Debug, PartialEq)]
pub enum Format { Elf, Mach, Pe }
#[derive(Debug, PartialEq)]
pub struct Evidence { name: Vec<u8>, offset: u64, kind: u32 }
#[derive(Debug)]
pub enum Cause {
    Budget(&'static str),
    Observed(Vec<u8>),
    Response,
}
impl Cause {
    fn io(path: &Path, error: io::Error) -> Self {
        Self::Observed(Outcome::Io(Err(error)).describe(Action::NativeInspection(path), Form::Action))
    }
    fn text(&self) -> Vec<u8> {
        match self {
            Self::Budget(resource) => format!("{} budget exceeded", resource).into_bytes(),
            Self::Observed(line) => line.clone(),
            Self::Response => b"inspection child returned an invalid result".to_vec(),
        }
    }
}
#[derive(Debug)]
pub enum Inspection { NativeImage(Format, Evidence), NotNative, Incomplete(Cause) }
impl Inspection {
    pub fn reason(&self) -> Option<Vec<u8>> {
        match self {
            Self::NativeImage(_, ev) => Some(cat(&[b"Native binary '", &ev.name, b"' found in node_modules/.bin"])),
            Self::NotNative => None,
            Self::Incomplete(cause) => Some(cat(&[b"Native binary inspection incomplete: ", &cause.text()])),
        }
    }
}

struct Budget { until: Instant, bytes: usize, list_bytes: usize, entries: usize }
impl Budget {
    fn new() -> Self { Self { until: Instant::now() + SCAN_TIME, bytes: 0, list_bytes: 0, entries: 0 } }
    fn time(&self) -> Result<(), Cause> {
        if Instant::now() >= self.until { Err(Cause::Budget("inspection time")) } else { Ok(()) }
    }
    fn list(&mut self, bytes: usize, entries: usize) -> Result<(), Cause> {
        self.time()?;
        if bytes > LIST_BYTES - self.list_bytes { return Err(Cause::Budget("directory/baseline bytes")) }
        if entries > LIST_ENTRIES - self.entries { return Err(Cause::Budget("directory/baseline entries")) }
        self.list_bytes += bytes; self.entries += entries;
        Ok(())
    }
}

fn baseline(path: &Path, budget: &mut Budget) -> Result<BTreeSet<Vec<u8>>, Cause> {
    let mut file = match fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(BTreeSet::new()),
        Err(e) => return Err(Cause::io(path, e)),
    };
    let size = file.metadata().map_err(|e| Cause::io(path, e))?.len();
    if size > LIST_BYTES as u64 { return Err(Cause::Budget("directory/baseline bytes")) }
    budget.list(size as usize, 0)?;
    let mut bytes = vec![0; size as usize];
    file.read_exact(&mut bytes).map_err(|e| Cause::io(path, e))?;
    // A growing snapshot is not silently treated as the prefix we read.
    let mut extra = [0];
    if file.read(&mut extra).map_err(|e| Cause::io(path, e))? != 0 {
        return Err(Cause::Observed(b"baseline changed size during inspection".to_vec()));
    }
    let mut names = BTreeSet::new();
    for line in bytes.split(|b| *b == b'\n').filter(|s| !s.is_empty()) {
        budget.list(0, 1)?;
        names.insert(line.to_vec());
    }
    Ok(names)
}

fn scan_inner(dir: &Path, old: &Path) -> Result<Inspection, Cause> {
    let mut budget = Budget::new();
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Inspection::NotNative),
        Err(e) => return Err(Cause::io(dir, e)),
    };
    let before = baseline(old, &mut budget)?;
    let mut names = Vec::new();
    for entry in entries {
        budget.time()?;
        let entry = entry.map_err(|e| Cause::io(dir, e))?;
        let name = entry.file_name();
        let name = sh::bytes(Path::new(&name));
        budget.list(name.len(), 1)?;
        if !name.starts_with(b".") && !before.contains(name) { names.push(name.to_vec()); }
    }
    names.sort();
    // This is the existing 20-name sample, not a complete directory audit.
    for name in names.into_iter().take(SAMPLE) {
        budget.time()?;
        let path = dir.join(sh::p(&name));
        if let Some((format, offset, kind)) = formats::inspect(&path, &mut budget)? {
            return Ok(Inspection::NativeImage(format, Evidence { name, offset, kind }));
        }
    }
    budget.time()?;
    Ok(Inspection::NotNative)
}
fn scan(dir: &Path, old: &Path) -> Inspection {
    scan_inner(dir, old).unwrap_or_else(Inspection::Incomplete)
}
