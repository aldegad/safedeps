// C's observation archive only. Inserted immediately after the sole raw read.
// This block neither replaces that read nor changes the value returned to callers.
    {
        use std::io::Write;
        use std::os::fd::FromRawFd;
        use std::sync::atomic::{AtomicU64, Ordering};
        static EVENT: AtomicU64 = AtomicU64::new(0);
        extern "C" { fn getppid() -> i32; }
        let ordinal = EVENT.fetch_add(1, Ordering::SeqCst);
        let (sign, duration) = match raw.duration_since(std::time::UNIX_EPOCH) {
            Ok(d) => ("after", d), Err(e) => ("before", e.duration()),
        };
        // FD 198 belongs to C's collector. No product env/CLI/feature selects it.
        // Keep it open for subsequent reads; a short/failed write is a missing
        // observation and must not affect the product's own return path.
        let mut sink = std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(198) });
        let line = format!("wall1\t{}\t{}\t{}\t{:?}\t{}\t{}\t{}\n",
            std::process::id(), unsafe { getppid() }, ordinal, _role,
            sign, duration.as_secs(), duration.subsec_nanos());
        let _ = sink.write_all(line.as_bytes());
    }
