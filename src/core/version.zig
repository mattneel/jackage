//! Product and build identity (`CLI-001`).
//!
//! `--version` must report the product identity *and* the build identity: the
//! compiler that produced the binary, the target it was built for, and the
//! optimization mode. A version string alone cannot distinguish a build made by
//! the pinned compiler from one made by an arbitrary host toolchain.
const std = @import("std");
const builtin = @import("builtin");

pub const product_name = "jackage";
pub const product_version = "0.1.0-dev";
/// The command-line and structured-output contract this build implements.
pub const interface_version = "jackage-cli-v1";

pub const BuildIdentity = struct {
    product: []const u8 = product_name,
    version: []const u8 = product_version,
    interface: []const u8 = interface_version,
    /// The compiler that compiled this binary.
    build_zig_version: []const u8 = builtin.zig_version_string,
    target: []const u8,
    optimize_mode: []const u8,
    is_debug_build: bool,
};

pub fn optimizeModeText(mode: std.lang.Optimize) []const u8 {
    return switch (mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

/// Identity of the running binary.
pub fn buildIdentity(gpa: std.mem.Allocator) std.mem.Allocator.Error!BuildIdentity {
    const target = try gpa.print("{s}-{s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    return .{
        .target = target,
        .optimize_mode = optimizeModeText(builtin.mode),
        .is_debug_build = builtin.mode == .debug,
    };
}

pub fn deinitIdentity(gpa: std.mem.Allocator, identity: BuildIdentity) void {
    gpa.free(identity.target);
}

pub const JsonIdentity = struct {
    product: []const u8,
    version: []const u8,
    interface: []const u8,
    buildZigVersion: []const u8,
    target: []const u8,
    optimizeMode: []const u8,
    debugBuild: bool,
};

pub fn jsonIdentity(identity: BuildIdentity) JsonIdentity {
    return .{
        .product = identity.product,
        .version = identity.version,
        .interface = identity.interface,
        .buildZigVersion = identity.build_zig_version,
        .target = identity.target,
        .optimizeMode = identity.optimize_mode,
        .debugBuild = identity.is_debug_build,
    };
}

test "m01/CLI-001 report real version" {
    std.debug.print("JCKG_EVIDENCE CLI-001\n", .{});
    const gpa = std.testing.allocator;

    const identity = try buildIdentity(gpa);
    defer deinitIdentity(gpa, identity);

    try std.testing.expectEqualStrings("jackage", identity.product);
    try std.testing.expect(identity.version.len > 0);
    try std.testing.expectEqualStrings("jackage-cli-v1", identity.interface);

    // The build identity names the compiler that produced this binary, which
    // the checkout pins separately in .zigversion.
    try std.testing.expectEqualStrings(builtin.zig_version_string, identity.build_zig_version);
    try std.testing.expect(identity.build_zig_version.len > 0);
    // Evidence for this case runs through scripts/zig.ps1, so the build
    // compiler must be the pinned one; a different compiler is a finding.
    try std.testing.expectEqualStrings("0.18.0-dev.146+35accc06e", identity.build_zig_version);

    var expected_target_buffer: [32]u8 = undefined;
    const expected_target = try std.mem.print(&expected_target_buffer, "{s}-{s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });
    try std.testing.expectEqualStrings(expected_target, identity.target);
    try std.testing.expectEqualStrings("Debug", identity.optimize_mode);
    try std.testing.expect(identity.is_debug_build);

    // Negative-or-recovery: the identity cannot be empty or a placeholder, and
    // an unknown optimization mode never reaches the document.
    try std.testing.expect(identity.version.len >= 5);
    try std.testing.expect(std.mem.indexOf(u8, identity.version, "0.0.0") == null);
    try std.testing.expectEqualStrings("ReleaseSafe", optimizeModeText(.ReleaseSafe));
    try std.testing.expectEqualStrings("ReleaseSmall", optimizeModeText(.ReleaseSmall));

    const document = jsonIdentity(identity);
    try std.testing.expectEqualStrings("jackage", document.product);
    try std.testing.expectEqualStrings(identity.target, document.target);
}
