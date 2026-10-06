"""Source-only operation faults shared by focused and full e2e measurements."""

EDITS = {
    'walk': ('rust/src/post/trace.rs', '    let mut todo=vec![(root.to_path_buf(),0)];',
             '    if until.is_some(){std::thread::sleep(Duration::from_millis(1100));}\n    let mut todo=vec![(root.to_path_buf(),0)];'),
    'coarse': ('rust/src/post/trace.rs', 'if (m.ctime(),m.ctime_nsec())>(b.mtime(),b.mtime_nsec())',
               'if (m.ctime(),0)>(b.mtime(),b.mtime_nsec())'),
    'owner': ('rust/src/post/process.rs', 'unsafe{proc_pidinfo(pid,3,1,&mut b as *mut _ as *mut _,size)}', '0'),
}

# Pre observes the node root through the same native clock reader as ordinary
# files. Quantize only that returned observation, retaining its real seconds.
# Used on archive copies together with EDITS['coarse'] for the post walk.
PRE_EDITS = {
    'coarse': ('rust/src/pre.rs',
        '        if os::clock_has_subsecond(&os::tree_clock(&path)) {',
        '''        let observed=os::tree_clock(&path);
        let observed=if path.file_name().is_some_and(|n|n=="node_modules") {
            observed.split('|').map(|v|v.split('.').next().unwrap_or(v)).collect::<Vec<_>>().join("|")
        }else{observed};
        if os::clock_has_subsecond(&observed) {'''),
}
