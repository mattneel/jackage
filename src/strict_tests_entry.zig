//! Test entry point for the guest sandbox suite (M08).
//!
//! The suite lives under `src/worker/`, which imports the shared trust and
//! canonical modules; a test module's imports may not escape its root file's
//! directory, so the entry sits at `src/` and pulls the suite in.
test {
    _ = @import("package/docker_tests.zig");
    _ = @import("platform/debian.zig");
    _ = @import("worker/strict_tests.zig");
}
