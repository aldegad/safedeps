//! Fixed image headers. Sources: ELF gABI §2; Microsoft PE/COFF;
//! Apple mach-o/{loader,fat}.h and dyld FatFile (verified 2026-10-13).
//! https://gabi.xinuos.com/elf/02-eheader.html
//! https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
//! https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/common/MachOFile.cpp
//! https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/mach_fat.c
use super::{Budget, Cause, Format, FILE_BYTES, TOTAL_BYTES};
use std::{fs, io::{Read, Seek, SeekFrom}, path::Path};

struct Image<'a> { file: fs::File, path: &'a Path, len: u64, used: usize, budget: &'a mut Budget }
impl Image<'_> {
    fn read(&mut self, offset: u64, size: usize) -> Result<Vec<u8>, Cause> {
        self.budget.time()?;
        if size > FILE_BYTES - self.used { return Err(Cause::Budget("per-file read bytes")) }
        if size > TOTAL_BYTES - self.budget.bytes { return Err(Cause::Budget("total candidate read bytes")) }
        self.used += size; self.budget.bytes += size;
        let mut bytes = vec![0; size];
        self.file.seek(SeekFrom::Start(offset)).and_then(|_| self.file.read_exact(&mut bytes))
            .map_err(|e| Cause::io(self.path, e))?;
        Ok(bytes)
    }
}
fn fits(offset: u64, size: u64, len: u64) -> bool { offset <= len && size <= len - offset }
fn u16_at(b: &[u8], i: usize, little: bool) -> u16 {
    let a = b[i..i+2].try_into().unwrap(); if little { u16::from_le_bytes(a) } else { u16::from_be_bytes(a) }
}
fn u32_at(b: &[u8], i: usize, little: bool) -> u32 {
    let a = b[i..i+4].try_into().unwrap(); if little { u32::from_le_bytes(a) } else { u32::from_be_bytes(a) }
}
fn u64_at(b: &[u8], i: usize, little: bool) -> u64 {
    let a = b[i..i+8].try_into().unwrap(); if little { u64::from_le_bytes(a) } else { u64::from_be_bytes(a) }
}

fn elf(b: &[u8], len: u64) -> Option<u32> {
    if b.len() < 16 || b[6] != 1 { return None }
    let (size, phsize) = match b[4] { 1 => (52,32), 2 => (64,56), _ => return None };
    let little = match b[5] { 1 => true, 2 => false, _ => return None };
    if b.len() < size { return None }
    let kind = u16_at(b,16,little);
    if !matches!(kind,2|3) || u16_at(b,18,little) == 0 || u32_at(b,20,little) != 1 { return None }
    let (phoff, h) = if size == 52 { (u32_at(b,28,little) as u64,40) } else { (u64_at(b,32,little),52) };
    let count = u16_at(b,h+4,little) as u64;
    if u16_at(b,h,little) as usize != size || u16_at(b,h+2,little) != phsize || count == 0
        || phoff < size as u64 || !fits(phoff,count * phsize as u64,len) { return None }
    Some(kind as u32)
}

// The complete fixed header and the stated load-command envelope, not the
// commands, signatures, architecture availability, or dependent libraries.
fn mach(b: &[u8], len: u64) -> Option<(u32,u32,u32)> {
    let (little,size) = match b.get(..4)? {
        [0xfe,0xed,0xfa,0xce] => (false,28), [0xce,0xfa,0xed,0xfe] => (true,28),
        [0xfe,0xed,0xfa,0xcf] => (false,32), [0xcf,0xfa,0xed,0xfe] => (true,32),
        _ => return None,
    };
    if b.len() < size { return None }
    let cpu = u32_at(b,4,little); let sub = u32_at(b,8,little);
    let kind = u32_at(b,12,little); let count = u32_at(b,16,little) as u64;
    let bytes = u32_at(b,20,little) as u64;
    if cpu == 0 || !matches!(kind,2|6|7|8) || count == 0 || bytes < count * 8
        || !fits(size as u64,bytes,len) { return None }
    Some((cpu,sub,kind))
}

fn pe(image: &mut Image<'_>, dos: &[u8]) -> Result<Option<u32>, Cause> {
    if dos.len() < 64 { return Ok(None) }
    let offset = u32_at(dos,60,true) as u64;
    if offset < 64 || !fits(offset,24,image.len) { return Ok(None) }
    let coff = image.read(offset,24)?;
    if &coff[..4] != b"PE\0\0" || u16_at(&coff,4,true) == 0 { return Ok(None) }
    let sections = u16_at(&coff,6,true) as u64;
    let size = u16_at(&coff,20,true) as u64;
    let flags = u16_at(&coff,22,true);
    if flags & 2 == 0 || sections == 0 || size < 96 || !fits(offset+24,size+sections*40,image.len) { return Ok(None) }
    // Read the complete optional header (bounded by the same file budget).
    let opt = image.read(offset+24,size as usize)?;
    let (minimum,dirs) = match u16_at(&opt,0,true) { 0x10b => (96,92), 0x20b => (112,108), _ => return Ok(None) };
    if opt.len() < minimum { return Ok(None) }
    let count = u32_at(&opt,dirs,true) as u64;
    let headers = u32_at(&opt,60,true) as u64;
    if count * 8 > size - minimum as u64 || headers < offset+24+size+sections*40
        || headers > image.len || u32_at(&opt,32,true) == 0 || u32_at(&opt,36,true) == 0
        || u32_at(&opt,56,true) == 0 { return Ok(None) }
    Ok(Some(flags as u32))
}

fn fat(image: &mut Image<'_>, head: &[u8], wide: bool) -> Result<Option<(u64,u32)>, Cause> {
    if head.len() < 8 { return Ok(None) }
    let count = u32_at(head,4,false) as usize;
    let stride = if wide { 32 } else { 20 };
    // Explicit profile envelope: XNU's 16KiB FAT32 table; dyld FatFile's
    // 4KiB FAT64 table. An impossible count is a mismatch, not exhaustion
    // (CAFEBABE also starts ordinary and preview Java class files).
    let max = if wide { 127 } else { (16 * 1024 - 8) / 20 };
    if count > max { return Ok(None) }
    let end = 8 + count * stride;
    if end as u64 > image.len { return Ok(None) }
    let hidden = !wide && end + stride <= 4096;
    let prefix = (end + if hidden { stride } else { 0 }).min(image.len as usize);
    let table = image.read(0,prefix)?;
    for i in 0..count + usize::from(hidden && table.len() >= end+stride) {
        let start = 8+i*stride;
        let cpu = u32_at(&table,start,false); let sub = u32_at(&table,start+4,false);
        if i == count && cpu != 0x0100_000c { continue } // dyld's extra ARM64 slot
        let (offset,size,align) = if wide {
            (u64_at(&table,start+8,false), u64_at(&table,start+16,false),u32_at(&table,start+24,false))
        } else {
            (u32_at(&table,start+8,false) as u64,u32_at(&table,start+12,false) as u64,u32_at(&table,start+16,false))
        };
        if size < 28 || offset < end as u64 || !fits(offset,size,image.len)
            || align >= 64 || offset % (1u64 << align) != 0 { continue }
        let header = image.read(offset,32.min(size as usize))?;
        if let Some((actual_cpu,actual_sub,kind)) = mach(&header,size) {
            if cpu == actual_cpu && sub & 0x00ff_ffff == actual_sub & 0x00ff_ffff {
                return Ok(Some((offset,kind)))
            }
        }
    }
    Ok(None)
}

pub(super) fn inspect(path: &Path, budget: &mut Budget) -> Result<Option<(Format,u64,u32)>, Cause> {
    let meta = fs::metadata(path).map_err(|e| Cause::io(path,e))?;
    if !meta.is_file() { return Ok(None) }
    let file = fs::File::open(path).map_err(|e| Cause::io(path,e))?;
    let meta = file.metadata().map_err(|e| Cause::io(path,e))?;
    if !meta.is_file() { return Ok(None) }
    let mut image = Image { file, path, len: meta.len(), used: 0, budget };
    let head = image.read(0,64.min(image.len as usize))?;
    let Some(magic) = head.get(..4) else { return Ok(None) };
    if magic == b"\x7fELF" { return Ok(elf(&head,image.len).map(|kind| (Format::Elf,0,kind))) }
    if let Some((_,_,kind)) = mach(&head,image.len) { return Ok(Some((Format::Mach,0,kind))) }
    if head.starts_with(b"MZ") { return pe(&mut image,&head).map(|v| v.map(|kind| (Format::Pe,0,kind))) }
    let wide = match magic { [0xca,0xfe,0xba,0xbe] => false, [0xca,0xfe,0xba,0xbf] => true, _ => return Ok(None) };
    fat(&mut image,&head,wide).map(|v| v.map(|(offset,kind)| (Format::Mach,offset,kind)))
}
