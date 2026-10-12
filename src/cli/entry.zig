//! Executable entry point for `jckg`.
//!
//! The client's behavior lives in the library module so it can be tested
//! directly; this file only forwards the process entry point.
const std = @import("std");
const jckg = @import("jckg");

pub fn main(init: std.process.Init) !void {
    return jckg.cli.main(init);
}
