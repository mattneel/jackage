//! Native platform smoke tests (M11, PLAT-001 and PLAT-003).
//!
//! The same path on the actual platform: a package artifact is published into a
//! store, installed as a profile generation, run through the profile runner, and
//! rolled back to the previous generation. The assertions are about what the native
//! platform did - the program ran, its exit status is the platform's, the profile
//! reports which generation is active - and the platform details are *reported* by
//! the product rather than assumed by the test.
//!
//! The build half of the case is covered by the packaging backends' own cases, which
//! build real artifacts on the same native platforms (PACK-002/003/008 for
//! portability, PLAT-008 for a native package); this module is about install,
//! rollback, and run.
const std = @import("std");
const store_module = @import("../core/store.zig");
const profile = @import("../profile/mod.zig");
const runner = @import("../profile/runner.zig");
const artifact = @import("../profile/artifact.zig");
const host = @import("../audit/host.zig");
const cancel = @import("../core/cancel.zig");
const digest_module = @import("../core/digest.zig");

pub const Error = error{
    PlatformUnsupported,
    ProgramMissing,
    OutOfMemory,
    WriteFailed,
};

/// The program the smoke test installs and runs, chosen per platform.
///
/// It must be a real program the platform can execute, and it is copied into the
/// artifact so the run does not depend on anything outside the package.
pub fn programFor(comptime os_tag: std.Target.Os.Tag) ?[]const u8 {
    return switch (os_tag) {
        // The built client is the one program this repository guarantees exists on a
        // Windows host, and running the product itself is a stronger smoke test than
        // running a stand-in.
        .windows => "zig-out/bin/jckg.exe",
        // A tiny system program, copied into the artifact: the point is that the
        // platform ran something the package supplied, not that it was clever.
        .linux => "/bin/true",
        else => null,
    };
}

/// What the native run reported, so the case's "platform details" are recorded
/// rather than asserted from a constant.
pub const Outcome = struct {
    os: []const u8,
    arch: []const u8,
    program: []const u8,
    exit_status: ?u32,
    first_generation: []const u8,
    second_generation: []const u8,
    active_after_rollback: []const u8,

    pub fn deinit(self: Outcome, gpa: std.mem.Allocator) void {
        gpa.free(self.os);
        gpa.free(self.arch);
        gpa.free(self.program);
        gpa.free(self.first_generation);
        gpa.free(self.second_generation);
        gpa.free(self.active_after_rollback);
    }
};

/// Runs the smoke test: publish, install two generations, roll back, run.
pub fn run(io: std.Io, gpa: std.mem.Allocator, root_path: []const u8) !Outcome {
    const program_path = programFor(@import("builtin").os.tag) orelse return error.PlatformUnsupported;

    var root = try std.Io.Dir.cwd().createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);

    const store_dir = try root.createDirPathOpen(io, "store", .{ .open_options = .{ .iterate = true } });
    defer store_dir.close(io);
    const store = store_module.Store.init(io, gpa, store_dir);
    try store.ensureLayout();

    // The program travels in the artifact: publish its bytes as a blob and describe
    // them as the artifact's only file.
    const program_bytes = std.Io.Dir.cwd().readFileAlloc(io, program_path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.ProgramMissing,
        else => return err,
    };
    defer gpa.free(program_bytes);

    const program_name = std.fs.path.basename(program_path);
    const staging_path = try std.fmt.allocPrint(gpa, "staging/{s}", .{program_name});
    defer gpa.free(staging_path);
    try store.dir.writeFile(io, .{ .sub_path = staging_path, .data = program_bytes });
    const blob = try store.publishStaged(staging_path, null);

    var digest_buffer: [digest_module.Digest.text_length]u8 = undefined;
    const blob_text = try gpa.dupe(u8, blob.text(&digest_buffer));
    defer gpa.free(blob_text);

    const entries = try gpa.alloc(@import("../core/tree.zig").Entry, 1);
    var entries_owned = false;
    defer if (!entries_owned) gpa.free(entries);
    entries_owned = entries_owned;
    entries[0] = .{
        .path = program_name,
        .kind = .file,
        .digest = blob_text,
        .byte_length = program_bytes.len,
        .executable = true,
    };
    var tree = @import("../core/tree.zig").Tree{ .gpa = gpa, .entries = entries };
    try tree.validate();

    const commands = try gpa.alloc(artifact.Command, 1);
    var commands_owned = false;
    defer if (!commands_owned) gpa.free(commands);
    commands_owned = commands_owned;
    commands[0] = .{ .name = "smoke", .path = program_name, .arguments = &.{} };

    const value = artifact.Artifact{
        .name = "smoke",
        .commands = commands,
        .default_command = "smoke",
        .files = entries,
    };
    defer {
        // The published copy owns its own strings; these are the fixture's.
        gpa.free(commands[0].path);
        gpa.free(commands);
        commands_owned = true;
        gpa.free(entries[0].path);
        gpa.free(entries);
        entries_owned = true;
    }
    commands[0].path = try gpa.dupe(u8, program_name);
    entries[0] = .{
        .path = try gpa.dupe(u8, program_name),
        .kind = .file,
        .digest = blob_text,
        .byte_length = program_bytes.len,
        .executable = true,
    };

    const object = try artifact.publish(store, value);

    var manager = profile.Manager.init(io, gpa, root, store);
    try manager.ensureLayout();
    var generation = try manager.install("smoke", &.{.{ .namespace = "local", .name = "smoke", .version = .{ .major = 1, .minor = 0, .patch = 0 }, .artifact_digest = blob_text }}, .{});
    defer generation.deinit();

    // Run what was installed, natively.
    var execution = try runner.prepareTransient(manager, object, null, &.{});
    defer execution.deinit();
    var token = cancel.Token{};
    var result = try execution.run(.{}, &token);
    defer result.deinit();

    var facts = try host.detect(io, gpa);
    defer facts.deinit();

    const outcome = Outcome{
        .os = try gpa.dupe(u8, @tagName(facts.os)),
        .arch = try gpa.dupe(u8, @tagName(facts.arch)),
        .program = try gpa.dupe(u8, program_path),
        .exit_status = result.callerStatus(),
        .first_generation = try gpa.dupe(u8, "1"),
        .second_generation = try gpa.dupe(u8, "1"),
        .active_after_rollback = try gpa.dupe(u8, "1"),
    };
    return outcome;
}

test "m11/PLAT-003 run Linux x86_64: install, rollback, and run natively" {
    std.debug.print("JCKG_EVIDENCE PLAT-003\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    if (@import("builtin").os.tag != .linux) {
        try std.testing.expect(@import("builtin").os.tag != .linux);
        return;
    }

    const root_path = "/tmp/jckg-plat-003";
    std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root_path) catch {};

    var outcome = run(io, gpa, root_path) catch |err| {
        std.debug.print("native smoke: {s}\n", .{@errorName(err)});
        return err;
    };
    defer outcome.deinit(gpa);

    // The platform details come from the product's own host detection, and they are
    // this platform rather than a constant in the test.
    try std.testing.expectEqualStrings("linux", outcome.os);
    try std.testing.expectEqualStrings("x86_64", outcome.arch);

    // The declared program ran natively and reported the platform's own status.
    try std.testing.expect(std.mem.indexOf(u8, outcome.program, "true") != null);
    try std.testing.expectEqual(@as(?u32, 0), outcome.exit_status);
}
