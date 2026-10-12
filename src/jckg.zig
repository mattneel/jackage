//! Jackage product library.
//!
//! `src/root.zig` stays the scaffold's own package root; this file is the
//! root of the Jackage product library that the `jckg` and `jckgx` clients
//! link against.
const std = @import("std");

pub const audit = @import("audit/mod.zig");
pub const cli = @import("cli/jckg.zig");

// Test collection is explicit: Zig only runs tests in files that the test
// build actually analyses, so every product source file is named here.
// `std.testing.refAllDecls` is not transitive and would silently skip them.
test {
    _ = @import("audit/mod.zig");
    _ = @import("audit/pin.zig");
    _ = @import("audit/host.zig");
    _ = @import("audit/inventory.zig");
    _ = @import("audit/provenance.zig");
    _ = @import("audit/manifest.zig");
    _ = @import("audit/baseline.zig");
    _ = @import("audit/hostenv.zig");
    _ = @import("core/cancel.zig");
    _ = @import("core/canonical.zig");
    _ = @import("core/capabilities.zig");
    _ = @import("core/digest.zig");
    _ = @import("core/policy.zig");
    _ = @import("core/redact.zig");
    _ = @import("core/store.zig");
    _ = @import("core/tree.zig");
    _ = @import("core/version.zig");
    _ = @import("cli/app.zig");
    _ = @import("cli/args.zig");
    _ = @import("cli/console.zig");
    _ = @import("cli/context.zig");
    _ = @import("cli/exit.zig");
    _ = @import("cli/output.zig");
    _ = @import("cli/commands/doctor.zig");
    _ = @import("cli/commands/echo.zig");
    _ = @import("cli/commands/help.zig");
    _ = @import("cli/commands/init.zig");
    _ = @import("cli/commands/version.zig");
    _ = @import("cli/integration_tests.zig");
    _ = @import("eval/mod.zig");
    _ = @import("exec/mod.zig");
    _ = @import("plan/cache.zig");
    _ = @import("plan/lockfile.zig");
    _ = @import("package/closure.zig");
    _ = @import("platform/debian.zig");
    _ = @import("platform/native_smoke.zig");
    _ = @import("space/cache_policy.zig");
    _ = @import("space/lease_recovery.zig");
    _ = @import("space/source_protection.zig");
    _ = @import("space/roots.zig");
    _ = @import("space/snapshot_capture.zig");
    _ = @import("platform/perimeter.zig");
    _ = @import("platform/windows_fs.zig");
    _ = @import("package/oci.zig");
    _ = @import("package/plan.zig");
    _ = @import("package/signing.zig");
    _ = @import("package/roundtrip.zig");
    _ = @import("package/tar.zig");
    _ = @import("package/zip.zig");
    _ = @import("plan/planner.zig");
    _ = @import("plan/resolver.zig");
    _ = @import("plan/version.zig");
    _ = @import("profile/mod.zig");
    _ = @import("trust/archive.zig");
    _ = @import("trust/download.zig");
    _ = @import("trust/keys.zig");
    _ = @import("trust/metadata.zig");
    _ = @import("trust/root.zig");
    _ = @import("worker/auth.zig");
    _ = @import("worker/controller.zig");
    _ = @import("selfhost/bootstrap.zig");
    _ = @import("selfhost/snapshot.zig");
    _ = @import("selfhost/environment.zig");
    _ = @import("selfhost/install.zig");
    _ = @import("selfhost/stage.zig");
    _ = @import("selfhost/stages.zig");
    _ = @import("worker/cross_tests.zig");
    _ = @import("worker/frames.zig");
    _ = @import("worker/main.zig");
    _ = @import("worker/sandbox.zig");
}
