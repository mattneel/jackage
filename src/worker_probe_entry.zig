//! Executable entry point for `jckg-probe`.
//!
//! Same layout rule as the worker: the probe's checks live under `src/worker/`,
//! so the executable root sits at `src/` and forwards the entry point.
const std = @import("std");
const probe = @import("worker/probe.zig");

pub fn main(init: std.process.Init) !void {
    return probe.main(init);
}
