//! Test root for the evaluation module (M04 work unit).
//!
//! The module lives under `src/eval/`, but it imports shared code such as
//! `src/core/**`. Compiling `src/eval/mod.zig` as its own module root would
//! reject those imports as outside the module path, so the test root sits one
//! level up and simply pulls the module in. The build installs the resulting
//! binary as `zig-out/bin/eval-tests`, which `scripts/test.ps1` runs.
const std = @import("std");

test {
    _ = @import("eval/mod.zig");
    std.testing.refAllDecls(@This());
}
