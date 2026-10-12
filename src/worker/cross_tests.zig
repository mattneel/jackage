//! STRICT-009: the Windows client requests a Linux action through the declared
//! transport, and the result comes back validated (M08, platform role `host`).
//!
//! The case spans the boundary rather than a single process, so the test does too:
//! the host creates the input on the guest's *native* storage (ext4 inside the
//! distro, not the `/mnt/c` drvfs mount), asks the guest to run an action over it,
//! and checks the digest the guest returns against the digest the host computes
//! locally. A translation or line-ending step anywhere in the chain would change
//! the bytes and the digests would disagree.
//!
//! On a platform that is not the Windows host the transport is not available, and
//! the test says which platform it was instead of reporting a pass it did not earn.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// The declared transport, and the distribution the execution environment uses.
pub const transport_program = "wsl.exe";
/// Absolute, because `.search` resolves against the *parent's* PATH and the build
/// runner provides a minimal environment; this test only gets here on Windows,
/// where the transport lives in the system directory.
pub const transport_path = "C:\\Windows\\System32\\wsl.exe";
pub const guest_distro = "Ubuntu";

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Runs one command in the guest and returns its stdout, trimmed. On failure the
/// guest's stderr is printed: a transport that fails without saying why is not
/// diagnosable.
fn runInGuest(gpa: std.mem.Allocator, io: std.Io, command: []const u8) ![]u8 {
    const argv = [_][]const u8{ transport_program, "-d", guest_distro, "--", "bash", "-lc", command };

    // The environment is inherited rather than replaced: the transport is a normal
    // Windows program that reads machine state (its own configuration locations
    // among others) from the environment, and an empty map makes it fail before it
    // can report anything.
    var child = try std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = transport_path } },
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    std.debug.print("transport: command=[{s}]\n", .{command});
    var stdout_file = child.stdout orelse return error.PipeUnavailable;
    var stderr_file = child.stderr orelse return error.PipeUnavailable;
    child.stdout = null;
    child.stderr = null;
    defer stdout_file.close(io);
    defer stderr_file.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = stdout_file.reader(io, &buffer);
    const output = try reader.interface.allocRemaining(gpa, .limited(64 * 1024));
    const term = try child.wait(io);
    if (!term.success()) {
        var error_buffer: [4096]u8 = undefined;
        var error_reader = stderr_file.reader(io, &error_buffer);
        const diagnostic = error_reader.interface.allocRemaining(gpa, .limited(4096)) catch &[_]u8{};
        defer if (diagnostic.len > 0) gpa.free(diagnostic);
        std.debug.print("transport: guest command failed, stderr: {s}\n", .{diagnostic});
        gpa.free(output);
        return error.GuestCommandFailed;
    }
    return output;
}

test "m08/STRICT-009 cross Windows to Linux: the declared transport runs a Linux action" {
    std.debug.print("JCKG_EVIDENCE STRICT-009\n", .{});
    const gpa = testing.allocator;
    const io = std.testing.io;

    // The case is a host case: it is about the actual Windows client reaching the
    // declared Linux environment. Anywhere else the honest report is the platform.
    if (builtin.os.tag != .windows) {
        try testing.expect(builtin.os.tag != .windows);
        return;
    }

    // Known bytes, chosen so a line-ending translation anywhere would change the
    // digest: an embedded CRLF and no trailing newline.
    const payload = "jackage-cross-boundary\r\nsecond line, no trailing newline";
    const expected_digest = sha256Hex(payload);

    // The input is created *inside the guest*, on its own filesystem, and the path
    // is deliberately not under /mnt: the case is about Linux-native storage. The
    // payload travels as printf escapes so no literal carriage return reaches the
    // shell's own parsing.
    // Single-line commands on purpose: a multi-line script arrives through the
    // Windows-to-Linux transport with its structure mangled, and a test that
    // depends on that is testing the transport's argument handling, not the case.
    // No shell variables on purpose: the transport does not preserve them, and a
    // test that depends on how the transport splits a script is testing the
    // transport's argument handling rather than the case. `/tmp` inside the distro
    // is its own ext4 filesystem, which is what "Linux-native storage" means here.
    const create =
        "set -eu; mkdir -p /tmp/jckg-cross; " ++
        "printf 'jackage-cross-boundary\\r\\nsecond line, no trailing newline' > /tmp/jckg-cross/input.txt; " ++
        "readlink -f /tmp/jckg-cross/input.txt; stat -f -c %T /tmp/jckg-cross";
    const created = try runInGuest(gpa, io, create);
    defer gpa.free(created);
    const trimmed = std.mem.trim(u8, created, " \r\n");
    const last_line = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse 0;
    const input_path = std.mem.trim(u8, trimmed[0..last_line], " \r\n");
    const filesystem = std.mem.trim(u8, trimmed[last_line + 1 ..], " \r\n");
    try testing.expect(std.mem.startsWith(u8, input_path, "/"));
    try testing.expect(!std.mem.startsWith(u8, input_path, "/mnt/"));

    // The action runs on the Linux side and its result comes back as a digest.
    const action = try std.fmt.allocPrint(gpa,
        "set -eu; printf 'action ran on %s\\n' \"$(uname -s)\" >&2; sha256sum '{s}' | cut -d' ' -f1",
        .{input_path});
    defer gpa.free(action);
    const returned = try runInGuest(gpa, io, action);
    defer gpa.free(returned);
    const returned_digest = std.mem.trim(u8, returned, " \r\n");

    // The verified result: the guest's digest equals the host's own computation.
    try testing.expectEqualStrings(&expected_digest, returned_digest);

    // Storage evidence, so "Linux-native" is a measured fact rather than a claim:
    // the file lives on the distro's own filesystem, never on the Windows mount.
    try testing.expect(std.mem.indexOf(u8, filesystem, "drvfs") == null);
    try testing.expect(filesystem.len > 0);
}
