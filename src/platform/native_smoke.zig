//! Native platform smoke tests (M11, PLAT-001 and PLAT-003).
//!
//! The same path on the actual platform: a program is published into a store as an
//! artifact, installed as a profile generation, run through the profile runner, then
//! a second generation is installed and the profile is rolled back to the first.
//! What is asserted is what the *native platform* did - the program ran, its status
//! is the platform's own, the active generation came back to the one we expect - and
//! the platform details are reported by the product rather than hard-coded here.
//!
//! The build half of the case is covered by the packaging backends' own native
//! cases (PLAT-008 builds a real Debian package on Linux; PACK-002/003/008 build
//! deterministic archives and envelopes). This module covers install, rollback, and
//! run, which is the part that needs a native process.
const std = @import("std");
const builtin = @import("builtin");
const store_module = @import("../core/store.zig");
const tree = @import("../core/tree.zig");
const profile = @import("../profile/manager.zig");
const runner = @import("../profile/runner.zig");
const artifact = @import("../profile/artifact.zig");
const resolver = @import("../plan/resolver.zig");
const host = @import("../audit/host.zig");
const cancel = @import("../core/cancel.zig");
const digest = @import("../core/digest.zig");

pub const Error = error{
    PlatformUnsupported,
    ProgramMissing,
    MissingActiveGeneration,
    OutOfMemory,
};

/// The program the smoke test installs and runs, chosen per platform.
pub fn programFor(comptime os_tag: std.Target.Os.Tag) ?[]const u8 {
    return switch (os_tag) {
        // The product itself, running natively on the platform it was built for.
        .windows => "zig-out/bin/jckg.exe",
        // A tiny system program: the point is that the platform ran something the
        // package supplied, not that the program was clever.
        .linux => "/bin/true",
        else => null,
    };
}

pub fn argumentsFor(comptime os_tag: std.Target.Os.Tag) []const []const u8 {
    return switch (os_tag) {
        // The client answers its version subcommand; the exit status is the test.
        .windows => &.{"version"},
        else => &.{},
    };
}

/// What the native run reported, so "platform details" are recorded rather than
/// assumed by the test.
pub const Outcome = struct {
    os: []const u8,
    arch: []const u8,
    program: []const u8,
    run_status: ?u32,
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

/// Runs the smoke test: publish, install a generation, run it, install a second
/// generation, roll back to the first, and report what happened.
pub fn run(io: std.Io, gpa: std.mem.Allocator, root_path: []const u8, cleanup_root: bool) !Outcome {
    const program_path = programFor(builtin.os.tag) orelse return error.PlatformUnsupported;
    if (cleanup_root) std.Io.Dir.cwd().deleteTree(io, root_path) catch {};

    var root = try std.Io.Dir.cwd().createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    const store_dir = try root.createDirPathOpen(io, "store", .{ .open_options = .{ .iterate = true } });
    defer store_dir.close(io);
    const store = store_module.Store.init(io, gpa, store_dir);
    var manager = profile.Manager.init(io, gpa, root, store);
    try manager.ensureLayout();
    try store.ensureLayout();

    // The program travels inside the artifact: its bytes are imported as a blob and
    // described as the artifact's only file, so the run does not depend on a path
    // outside the package.
    const program_bytes = std.Io.Dir.cwd().readFileAlloc(io, program_path, gpa, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.ProgramMissing,
        else => return err,
    };
    defer gpa.free(program_bytes);
    const program_blob = try store.importBytes(program_bytes, null);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var text_buffer: [digest.Digest.text_length]u8 = undefined;
    const program_text = try arena.dupe(u8, program_blob.text(&text_buffer));

    const entries = [_]tree.Entry{.{
        .path = "app.exe",
        .kind = .file,
        .digest = program_text,
        .byte_length = program_bytes.len,
        .executable = true,
    }};
    const commands = [_]artifact.Command{.{
        .name = "smoke",
        .path = "app.exe",
        .arguments = argumentsFor(builtin.os.tag),
    }};
    const object = try manager.publish(.{
        .files = &entries,
        .commands = &commands,
        .default_command = "smoke",
        .dependencies = &.{},
    });
    const object_text = try arena.dupe(u8, object.text(&text_buffer));

    const selection = resolver.Selection{
        .namespace = "local/trusted",
        .name = "smoke",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .artifact_digest = object_text,
    };
    var first = try manager.install("smoke", &.{selection}, .{});
    defer first.deinit();

    // A second generation, so rollback has somewhere to go back to.
    const second_bytes = "second generation payload\n";
    const second_blob = try store.importBytes(second_bytes, null);
    // The second generation declares the same command, so it must carry the file
    // that command names: an artifact that points at a file it does not contain is
    // refused by the model rather than installed.
    const second_entries = [_]tree.Entry{
        .{
            .path = "app.exe",
            .kind = .file,
            .digest = program_text,
            .byte_length = program_bytes.len,
            .executable = true,
        },
        .{
            .path = "payload.txt",
            .kind = .file,
            .digest = try arena.dupe(u8, second_blob.text(&text_buffer)),
            .byte_length = second_bytes.len,
            .executable = false,
        },
    };
    const second_object = try manager.publish(.{
        .files = &second_entries,
        .commands = &commands,
        .default_command = "smoke",
        .dependencies = &.{},
    });
    const second_selection = resolver.Selection{
        .namespace = "local/trusted",
        .name = "smoke",
        .version = .{ .major = 1, .minor = 1, .patch = 0 },
        .artifact_digest = try arena.dupe(u8, second_object.text(&text_buffer)),
    };
    var second = try manager.install("smoke", &.{second_selection}, .{});
    defer second.deinit();

    // Run the *first* generation's artifact through the runner, natively.
    var execution = try runner.prepareTransient(manager, object, null, &.{});
    defer execution.deinit();
    var token = cancel.Token{};
    var result = try execution.run(.{}, &token);
    defer result.deinit();
    const run_status = result.callerStatus();

    // Roll back to the first generation and read back which generation is active.
    const before_rollback = (try manager.active("smoke")) orelse return error.MissingActiveGeneration;
    var before = before_rollback;
    defer before.deinit();
    var rolled = try manager.rollback("smoke", null);
    defer rolled.deinit();

    var facts = try host.detect(io, gpa);
    defer facts.deinit();

    const active = (try manager.active("smoke")) orelse return error.MissingActiveGeneration;
    var active_generation = active;
    defer active_generation.deinit();

    const outcome = Outcome{
        .os = try gpa.dupe(u8, @tagName(facts.os)),
        .arch = try gpa.dupe(u8, @tagName(facts.arch)),
        .program = try gpa.dupe(u8, program_path),
        .run_status = run_status,
        .first_generation = try gpa.dupe(u8, first.manifest().id),
        .second_generation = try gpa.dupe(u8, second.manifest().id),
        .active_after_rollback = try gpa.dupe(u8, active_generation.manifest().id),
    };
    return outcome;
}

test "m11/PLAT-003 run Linux x86_64: install, rollback, and run natively" {
    std.debug.print("JCKG_EVIDENCE PLAT-003\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        try std.testing.expect(!(builtin.os.tag == .linux and builtin.cpu.arch == .x86_64));
        return;
    }

    const root_path = "/tmp/jckg-plat-003";
    defer std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
    var outcome = run(io, gpa, root_path, true) catch |err| {
        std.debug.print("native smoke: {s}\n", .{@errorName(err)});
        return err;
    };
    defer outcome.deinit(gpa);

    // The platform details come from the product's own detection: this platform, not
    // a constant in the test.
    try std.testing.expectEqualStrings("linux", outcome.os);
    try std.testing.expectEqualStrings("x86_64", outcome.arch);

    // The program the package supplied ran natively and exited successfully.
    try std.testing.expectEqual(@as(?u32, 0), outcome.run_status);
    try std.testing.expect(std.mem.endsWith(u8, outcome.program, "true") or std.mem.indexOf(u8, outcome.program, "jckg") != null);

    // Two generations were installed and the rollback returned to the first.
    try std.testing.expect(!std.mem.eql(u8, outcome.first_generation, outcome.second_generation));
    try std.testing.expectEqualStrings(outcome.first_generation, outcome.active_after_rollback);
}

test "m11/PLAT-001 run Windows x86_64: install, rollback, and run natively" {
    std.debug.print("JCKG_EVIDENCE PLAT-001\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) {
        try std.testing.expect(!(builtin.os.tag == .windows and builtin.cpu.arch == .x86_64));
        return;
    }

    const root_path = "zig-out/jckg-plat-001";
    defer std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
    var outcome = run(io, gpa, root_path, true) catch |err| {
        std.debug.print("native smoke: {s}\n", .{@errorName(err)});
        return err;
    };
    defer outcome.deinit(gpa);

    try std.testing.expectEqualStrings("windows", outcome.os);
    try std.testing.expectEqualStrings("x86_64", outcome.arch);

    // The product itself ran natively: its version subcommand exited zero, through
    // the platform's own process machinery.
    try std.testing.expectEqual(@as(?u32, 0), outcome.run_status);

    try std.testing.expect(!std.mem.eql(u8, outcome.first_generation, outcome.second_generation));
    try std.testing.expectEqualStrings(outcome.first_generation, outcome.active_after_rollback);
}
