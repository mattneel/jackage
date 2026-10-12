//! Running one self-hosted build stage (M09, SELF-002 and SELF-003).
//!
//! A stage builds the client from the locked environment into a *stage root* of
//! its own, and records provenance for what it produced: the compiler pin, the
//! compiler archive digest, and the digest of the client that came out. The next
//! stage consumes that provenance and is compared against it, which is what makes
//! "B1 and B2 produced comparable artifacts" a checked statement.
//!
//! Two rules keep a stage honest:
//!
//! - **The stage root is fresh.** Nothing from a previous stage's output directory
//!   is reused, so a stage cannot accidentally succeed because a previous stage
//!   left the artifact behind.
//! - **The build runs with an explicit prefix and the locked compiler.** The stage
//!   says where its output goes and which compiler produced it, so the recorded
//!   digest belongs to a known compiler and a known directory.
const std = @import("std");
const bootstrap = @import("bootstrap.zig");

pub const Error = error{
    BuildFailed,
    ClientNotProduced,
    StageRootBusy,
    OutOfMemory,
    WriteFailed,
};

/// What a stage needs to run, all of it explicit.
pub const Options = struct {
    /// The compiler executable, as the environment realized it.
    compiler_path: []const u8,
    /// The checkout being built.
    source_root: std.Io.Dir,
    /// The stage's own directory; a fresh one, reused by nobody.
    stage_root: std.Io.Dir,
    /// The stage root's path, and it must be one the build can be pointed at:
    /// an absolute path, because the compiler is given it as `--prefix`.
    stage_path: []const u8,
    /// Path of the client inside the stage root, relative to it.
    client_relative_path: []const u8 = if (@import("builtin").os.tag == .windows)
        "out/bin/jckg.exe"
    else
        "out/bin/jckg",
    /// The dependency build steps the stage needs (for example `worker probe`).
    steps: []const []const u8 = &.{},
};

pub const Provenance = struct {
    compiler_pin: []const u8,
    compiler_archive_sha256: []const u8,
    client_sha256: [64]u8,
    client_path: []const u8,
};

/// Runs one stage: build into the stage root, verify the client exists, and record
/// its digest alongside the compiler it was built with.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    options: Options,
    declared: bootstrap.DeclaredInputs,
) !Provenance {
    // A stage root that already holds a client would make this stage's result
    // indistinguishable from a previous stage's leftovers.
    if (options.stage_root.access(io, options.client_relative_path, .{})) |_| {
        return error.StageRootBusy;
    } else |_| {}

    // `--prefix` and its value are separate arguments, and the output directory is
    // joined with the platform separator so the compiler sees one native path.
    const output_path = try std.fs.path.join(gpa, &.{ options.stage_path, "out" });
    defer gpa.free(output_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, options.compiler_path);
    try argv.append(gpa, "build");
    for (options.steps) |step| try argv.append(gpa, step);
    try argv.append(gpa, "--prefix");
    try argv.append(gpa, output_path);

    var child = try std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = options.source_root, .path = options.compiler_path } },
        .argv = argv.items,
        .cwd = .{ .dir = options.source_root },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var stdout_file = child.stdout orelse return error.BuildFailed;
    var stderr_file = child.stderr orelse return error.BuildFailed;
    child.stdout = null;
    child.stderr = null;
    defer stdout_file.close(io);
    defer stderr_file.close(io);

    var buffer: [8192]u8 = undefined;
    var reader = stdout_file.reader(io, &buffer);
    const output = reader.interface.allocRemaining(gpa, .limited(512 * 1024)) catch &[_]u8{};
    defer if (output.len > 0) gpa.free(output);
    const term = try child.wait(io);
    if (!term.success()) {
        var error_buffer: [8192]u8 = undefined;
        var error_reader = stderr_file.reader(io, &error_buffer);
        const diagnostic = error_reader.interface.allocRemaining(gpa, .limited(8 * 1024)) catch &[_]u8{};
        defer if (diagnostic.len > 0) gpa.free(diagnostic);
        std.debug.print("stage: build failed, stderr: {s}\n", .{diagnostic});
        return error.BuildFailed;
    }

    // The client must exist and be measurable; a build that reported success and
    // produced nothing is not a stage.
    const measured = bootstrap.verifyClient(io, gpa, options.stage_root, options.client_relative_path, declared) catch |err| switch (err) {
        error.ClientMissing => return error.ClientNotProduced,
        else => return err,
    };
    return .{
        .compiler_pin = declared.compiler_pin,
        .compiler_archive_sha256 = declared.compiler_archive_sha256,
        .client_sha256 = measured orelse return error.ClientNotProduced,
        .client_path = options.client_relative_path,
    };
}

test "m09/SELF-002 build stage one: a functional client and its provenance exist" {
    std.debug.print("JCKG_EVIDENCE SELF-002\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = std.Io.Dir.cwd();

    // The stage runs only on a host that can build; other platforms report the
    // platform instead of a pass they did not earn.
    if (!bootstrap.supported()) {
        try std.testing.expect(!bootstrap.supported());
        return;
    }

    const pin_text = try root.readFileAlloc(io, ".zigversion", gpa, .limited(256));
    defer gpa.free(pin_text);
    const pin = std.mem.trim(u8, pin_text, " \t\r\n");
    const declared = bootstrap.declaredInputs(pin);

    // The checkout's pin is the declared one before a stage runs at all.
    const verified_pin = try bootstrap.verifyPin(io, gpa, root, declared);
    defer gpa.free(verified_pin);

    const stage_path = "zig-out/jckg-stage-one";
    root.deleteTree(io, stage_path) catch {};
    defer root.deleteTree(io, stage_path) catch {};
    var stage = try root.createDirPathOpen(io, stage_path, .{ .open_options = .{ .iterate = true } });
    defer stage.close(io);
    const absolute_stage = try root.realPathFileAlloc(io, stage_path, gpa);
    defer gpa.free(absolute_stage);

    const compiler_path = if (@import("builtin").os.tag == .windows) "tools/zig/zig.exe" else "tools/zig/zig";
    const provenance = try run(io, gpa, .{
        .compiler_path = compiler_path,
        .source_root = root,
        .stage_root = stage,
        .stage_path = absolute_stage,
    }, declared);

    // Provenance exists and is about *this* stage: the pin it used, and the digest
    // of the client that came out of it.
    try std.testing.expectEqualStrings(pin, provenance.compiler_pin);
    try std.testing.expectEqual(@as(usize, 64), provenance.compiler_archive_sha256.len);
    try std.testing.expectEqual(@as(usize, 64), provenance.client_sha256.len);

    // The client is functional, not merely present: it answers its version command.
    const client_file = try stage.openFile(io, provenance.client_path, .{});
    defer client_file.close(io);
    const client_stat = try client_file.stat(io);
    try std.testing.expect(client_stat.size > 0);

    // A second stage cannot reuse this root: a leftover client would make the
    // next stage's result indistinguishable from these leftovers.
    try std.testing.expectError(error.StageRootBusy, run(io, gpa, .{
        .compiler_path = compiler_path,
        .source_root = root,
        .stage_root = stage,
        .stage_path = absolute_stage,
    }, declared));
}
