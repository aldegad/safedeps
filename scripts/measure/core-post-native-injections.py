"""Source-only operation faults shared by focused and full e2e measurements."""

EDITS = {
    'walk': ('rust/src/post/trace.rs', '    let mut todo=vec![(root.to_path_buf(),0)];',
             '    if until.is_some(){std::thread::sleep(Duration::from_millis(1100));}\n    let mut todo=vec![(root.to_path_buf(),0)];'),
    'coarse': ('rust/src/post/trace.rs', 'if (m.ctime(),m.ctime_nsec())>(b.mtime(),b.mtime_nsec())',
               'if (m.ctime(),0)>(b.mtime(),b.mtime_nsec())'),
    'owner': ('rust/src/post/process.rs', 'unsafe{proc_pidinfo(pid,3,1,&mut b as *mut _ as *mut _,size)}', '0'),
}
