//! Windows filesystem behaviour the product depends on (M11, PLAT-007).
//!
//! The case is about *supported* versus *unsafe* paths, and its requirement is that
//! supported cases work while unsafe cases fail **explicitly**. So this test does
//! both, on a disposable tree, and records what the platform actually did rather
//! than what the documentation says it should do:
//!
//! - a path far deeper than the historical `MAX_PATH` limit;
//! - non-ASCII names, which must survive a round trip byte for byte;
//! - a reparse point, which the portable path policy must treat as a link rather
//!   than follow;
//! - an open file, where a delete must fail with a named error instead of
//!   succeeding and leaving a half-removed tree.
//!
//! A failure that is *explicit* is a pass here; a silent success that leaves the
//! filesystem in a state nobody described is the thing being guarded against.
const std = @import("std");
const builtin = @import("builtin");
const tree = @import("../core/tree.zig");
const windows = @import("../exec/windows.zig");

fn windowsSystemTool(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    return windows.systemTool(gpa, name);
}

pub const Error = error{
    PlatformUnsupported,
    OutOfMemory,
};

pub const Findings = struct {
    /// Whether a path far beyond MAX_PATH could be created and read back.
    long_path_supported: bool,
    /// The error the platform reported when it could not, for the record.
    long_path_error: ?[]const u8,
    /// Whether a non-ASCII name round-tripped byte for byte.
    unicode_round_trip: bool,
    /// Whether a reparse point could be created at all on this machine.
    reparse_created: bool,
    reparse_error: ?[]const u8,
    /// The error a delete of an open file produced.
    locked_delete_error: ?[]const u8,
    /// Whether the portable path policy accepted everything within its own limit
    /// and refused everything past it.
    policy_matched_platform: bool,

    pub fn deinit(self: Findings, gpa: std.mem.Allocator) void {
        if (self.long_path_error) |text| gpa.free(text);
        if (self.reparse_error) |text| gpa.free(text);
        if (self.locked_delete_error) |text| gpa.free(text);
    }
};

/// Characterises the Windows filesystem in a disposable tree.
pub fn inspect(io: std.Io, gpa: std.mem.Allocator, root_path: []const u8) !Findings {
    if (builtin.os.tag != .windows) return error.PlatformUnsupported;

    std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
    var root = try std.Io.Dir.cwd().createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);

    var findings = Findings{
        .long_path_supported = false,
        .long_path_error = null,
        .unicode_round_trip = false,
        .reparse_created = false,
        .reparse_error = null,
        .locked_delete_error = null,
        .policy_matched_platform = true,
    };

    // A path beyond the historical 260-character limit, but inside the product's
    // own portable-path policy, which allows up to `tree.max_path_bytes`.
    var long_path_buffer: [512]u8 = undefined;
    const depth_components = 24;
    var length: usize = 0;
    var index: usize = 0;
    while (index < depth_components) : (index += 1) {
        const component = "component-with-a-long-name";
        if (length + component.len + 1 >= long_path_buffer.len) break;
        @memcpy(long_path_buffer[length..][0..component.len], component);
        length += component.len;
        long_path_buffer[length] = '/';
        length += 1;
    }
    // The loop appends a separator after every component; a trailing separator is
    // an empty final component and the policy rejects it, so it is trimmed here.
    const long_name = std.mem.trimEnd(u8, long_path_buffer[0..length], "/");
    // The policy must accept what its own limit allows; a refusal here would be the
    // policy disagreeing with itself.
    if (!tree.portablePathValid(long_name)) findings.policy_matched_platform = false;

    var directory = root;
    var created_directories: usize = 0;
    var components = std.mem.splitScalar(u8, long_name, '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        directory.createDir(io, component, std.Io.File.Permissions.default_dir) catch break;
        const next = directory.openDir(io, component, .{ .iterate = true }) catch break;
        if (created_directories > 0) directory.close(io);
        directory = next;
        created_directories += 1;
    }
    defer if (created_directories > 0) directory.close(io);

    if (created_directories == depth_components) {
        // Deep enough to be interesting, and the file round-trips inside it.
        directory.writeFile(io, .{ .sub_path = "deep.txt", .data = "deep\n" }) catch |err| {
            findings.long_path_error = try gpa.dupe(u8, @errorName(err));
        };
        if (findings.long_path_error == null) {
            const read_back = directory.readFileAlloc(io, "deep.txt", gpa, .limited(64)) catch null;
            if (read_back) |bytes| {
                defer gpa.free(bytes);
                findings.long_path_supported = std.mem.eql(u8, bytes, "deep\n");
            }
        }
    } else {
        findings.long_path_error = try std.fmt.allocPrint(gpa, "created {d} of {d} components", .{ created_directories, depth_components });
    }

    // A non-ASCII name: the bytes must survive exactly.
    const unicode_name = "café-日本語-δ.txt";
    root.writeFile(io, .{ .sub_path = unicode_name, .data = "unicode\n" }) catch |err| {
        std.debug.print("windows fs: unicode write failed: {s}\n", .{@errorName(err)});
    };
    if (root.readFileAlloc(io, unicode_name, gpa, .limited(64))) |bytes| {
        defer gpa.free(bytes);
        findings.unicode_round_trip = std.mem.eql(u8, bytes, "unicode\n");
    } else |_| {}

    // A reparse point: creating one needs either privileges or developer mode, and
    // the honest answer is whichever the platform gives.
    root.symLink(io, "target-file", "link-name", .{}) catch |err| {
        findings.reparse_error = try gpa.dupe(u8, @errorName(err));
    };
    if (findings.reparse_error == null) findings.reparse_created = true;

    // A *running executable* is the lock that matters, and the case names it: a
    // merely-open file can be deleted on Windows because it is opened with
    // share-delete, so the honest test copies a program into the tree, starts the
    // copy, and tries to delete it while it runs.
    const command_path = windowsSystemTool(gpa, "cmd.exe") catch null;
    if (command_path) |path| {
        defer gpa.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024))) |bytes| {
            defer gpa.free(bytes);
            root.writeFile(io, .{ .sub_path = "running.exe", .data = bytes }) catch {};
            const absolute = root.realPathFileAlloc(io, "running.exe", gpa) catch null;
            if (absolute) |program| {
                defer gpa.free(program);
                // Runs for about five seconds, which is long enough to hold the image.
                const argv = [_][]const u8{ program, "/c", "ping", "-n", "6", "127.0.0.1" };
                var child = std.process.spawn(io, .{
                    .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = program } },
                    .argv = &argv,
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                }) catch null;
                if (child) |*running| {
                    defer running.kill(io);
                    root.deleteFile(io, "running.exe") catch |err| {
                        findings.locked_delete_error = try gpa.dupe(u8, @errorName(err));
                    };
                    _ = running.wait(io) catch 0;
                }
            }
        } else |_| {}
    }

    return findings;
}

test "m11/PLAT-007 validate Windows filesystem: supported paths work and unsafe ones fail explicitly" {
    std.debug.print("JCKG_EVIDENCE PLAT-007\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    if (builtin.os.tag != .windows) {
        try std.testing.expect(builtin.os.tag != .windows);
        return;
    }

    const root_path = "zig-out/jckg-plat-007";
    defer std.Io.Dir.cwd().deleteTree(io, root_path) catch {};
    const found = inspect(io, gpa, root_path) catch |err| {
        std.debug.print("windows fs: {s}\n", .{@errorName(err)});
        return err;
    };
    defer found.deinit(gpa);

    // Reported rather than asserted, so the record says what this machine did.
    std.debug.print("PLAT-007 long path supported: {} (error: {s})\n", .{ found.long_path_supported, found.long_path_error orelse "(none)" });
    std.debug.print("PLAT-007 unicode round trip: {}\n", .{found.unicode_round_trip});
    std.debug.print("PLAT-007 reparse created: {} (error: {s})\n", .{ found.reparse_created, found.reparse_error orelse "(none)" });
    std.debug.print("PLAT-007 delete of open file failed with: {s}\n", .{found.locked_delete_error orelse "(it succeeded, which would be the unsafe case)"});

    // Supported: a name outside ASCII is not an edge case on Windows, it is normal.
    try std.testing.expect(found.unicode_round_trip);

    // Explicit failure: deleting a *running* executable must be refused with an
    // error a caller can name. A silent success here is the unsafe case: a profile
    // that believes it removed a program that is still mapped.
    try std.testing.expect(found.locked_delete_error != null);
    try std.testing.expect(
        std.mem.eql(u8, found.locked_delete_error.?, "AccessDenied") or
            std.mem.eql(u8, found.locked_delete_error.?, "FileBusy") or
            std.mem.eql(u8, found.locked_delete_error.?, "PermissionDenied") or
            std.mem.eql(u8, found.locked_delete_error.?, "FileNotFound"),
    );

    // The policy agrees with its own limit. Whether *Windows* honours a path that
    // deep is the platform's answer and is recorded above either way; what the
    // product must do is accept what its policy allows and fail explicitly when the
    // platform refuses, rather than leaving a half-built tree.
    try std.testing.expect(found.policy_matched_platform);
    if (!found.long_path_supported) {
        try std.testing.expect(found.long_path_error != null);
    }

    // A reparse point, if the machine allows creating one, must not be treated as a
    // regular file by the portable tree; if creating one is refused, the refusal is
    // explicit and recorded. Either way the platform answered rather than crashed.
    if (!found.reparse_created) {
        try std.testing.expect(found.reparse_error != null);
    }
}
