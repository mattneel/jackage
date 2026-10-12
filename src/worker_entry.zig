//! Executable entry point for `jckg-worker`.
//!
//! The worker's protocol and sandbox live under `src/worker/`, which also
//! imports the shared trust and canonical modules. A module's imports may not
//! escape its root file's directory, so the executable root sits here at `src/`
//! and forwards the process entry point.
const std = @import("std");
const worker = @import("worker/main.zig");

pub fn main(init: std.process.Init) !void {
    return worker.main(init);
}
