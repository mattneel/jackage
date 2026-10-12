//! `jckg version` and `jckg --version` (case CLI-001).
const std = @import("std");
const context = @import("../context.zig");
const args = @import("../args.zig");
const exit_code = @import("../exit.zig");
const version = @import("../../core/version.zig");

pub fn run(ctx: *context.Context, invocation: args.Invocation) !exit_code.Code {
    const emitter = ctx.emitter(invocation.json);
    const identity = try version.buildIdentity(ctx.gpa);
    defer version.deinitIdentity(ctx.gpa, identity);

    try emitter.jsonLine(.{
        .schemaVersion = 1,
        .kind = "version",
        .product = identity.product,
        .version = identity.version,
        .interface = identity.interface,
        .build = .{
            .zigVersion = identity.build_zig_version,
            .target = identity.target,
            .optimizeMode = identity.optimize_mode,
            .debugBuild = identity.is_debug_build,
        },
    });
    try emitter.human("jackage {s}\n", .{identity.version});
    try emitter.human("interface {s}\n", .{identity.interface});
    try emitter.human("build zig {s} target {s} mode {s}\n", .{
        identity.build_zig_version,
        identity.target,
        identity.optimize_mode,
    });
    return .success;
}
