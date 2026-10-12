//! Exporting a runtime closure as a root filesystem (M15, IMAGE-004).
//!
//! A root filesystem is the payload a guest boots or attaches: the files a program
//! needs, at the paths it expects, with the permissions that make it runnable. Two
//! properties make the export trustworthy, and they are checked rather than asserted:
//!
//! - **closure**: every object the manifest names is present with the digest the
//!   manifest declared, and the exported tree contains *nothing else*. The second
//!   half is the one that rots - a directory listing collects whatever was lying
//!   around - so the export is checked in both directions.
//! - **entry point**: the manifest's entry point exists and is executable, and it is
//!   actually run. A rootfs that cannot start its own program is a pile of files
//!   with a name.
//!
//! Paths are validated before anything is written: absolute paths, `..`, and empties
//! are refused, because an export writes to a destination directory and a path that
//! escapes it writes somewhere nobody asked for.
const std = @import("std");
const store_module = @import("../core/store.zig");
const digest = @import("../core/digest.zig");

pub const Error = error{
    InvalidManifest,
    InvalidPath,
    UnknownObject,
    DigestMismatch,
    MissingEntryPoint,
    EntryPointNotExecutable,
    ExtraFile,
    EntryPointFailed,
    WriteFailed,
    OutOfMemory,
};

pub const Object = struct {
    /// Path inside the exported rootfs, relative and without `..`.
    path: []const u8,
    digest: []const u8,
    executable: bool = false,
};

pub const Manifest = struct {
    name: []const u8,
    /// The program the rootfs is built to start.
    entry_point: []const u8,
    /// The runtime closure, as a locked manifest.
    objects: []const Object,
};

/// A rootfs path must be relative, must not escape, and must not be empty.
pub fn validPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
        if (std.mem.eql(u8, component, ".")) return false;
    }
    return true;
}

pub const Export = struct {
    files: usize,
    total_bytes: u64,
    /// The entry point as exported, which the caller may run.
    entry_point: []const u8,

    pub fn deinit(self: Export, gpa: std.mem.Allocator) void {
        gpa.free(self.entry_point);
    }
};

/// Writes the closure into `destination` as a root filesystem.
pub fn exportRootfs(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: store_module.Store,
    destination: std.Io.Dir,
    manifest: Manifest,
) Error!Export {
    if (manifest.name.len == 0 or manifest.objects.len == 0) return error.InvalidManifest;
    if (!validPath(manifest.entry_point)) return error.InvalidPath;

    var entry_found = false;
    for (manifest.objects, 0..) |object, index| {
        if (!validPath(object.path)) return error.InvalidPath;
        // Two objects at one path would make the export ambiguous, and the last write
        // would win by accident rather than by decision.
        for (manifest.objects[index + 1 ..]) |other| {
            if (std.mem.eql(u8, object.path, other.path)) return error.InvalidManifest;
        }
        const expected = digest.Digest.parse(object.digest) catch return error.InvalidManifest;
        if (!store.hasBlob(expected)) return error.UnknownObject;
        if (std.mem.eql(u8, object.path, manifest.entry_point)) {
            entry_found = true;
            // An entry point that cannot be executed is not an entry point. Checked
            // here, before the tree exists, so the refusal names the manifest.
            if (!object.executable) return error.EntryPointNotExecutable;
        }
    }
    if (!entry_found) return error.MissingEntryPoint;

    var files: usize = 0;
    var total: u64 = 0;
    for (manifest.objects) |object| {
        const expected = digest.Digest.parse(object.digest) catch return error.InvalidManifest;
        const bytes = store.readBlobAlloc(gpa, expected) catch return error.UnknownObject;
        defer gpa.free(bytes);

        if (std.fs.path.dirname(object.path)) |parent| {
            destination.createDirPath(io, parent) catch return error.WriteFailed;
        }
        const file = destination.createFile(io, object.path, .{ .truncate = true }) catch return error.WriteFailed;
        defer file.close(io);
        var scratch: [16 * 1024]u8 = undefined;
        var writer = file.writer(io, &scratch);
        writer.interface.writeAll(bytes) catch return error.WriteFailed;
        writer.interface.flush() catch return error.WriteFailed;

        // The executable bit is part of what a program is, so it is applied rather
        // than assumed from the umask.
        const mode: std.Io.File.Permissions = if (object.executable) .fromMode(0o755) else .fromMode(0o644);
        file.setPermissions(io, mode) catch return error.WriteFailed;
        files += 1;
        total += bytes.len;
    }
    return .{ .files = files, .total_bytes = total, .entry_point = try gpa.dupe(u8, manifest.entry_point) };
}

pub const ClosureReport = struct {
    present: usize,
    /// Entries in the exported tree that the manifest does not name.
    extra: []const []const u8,

    pub fn deinit(self: ClosureReport, gpa: std.mem.Allocator) void {
        for (self.extra) |path| gpa.free(path);
        gpa.free(self.extra);
    }

    pub fn ok(self: ClosureReport) bool {
        return self.extra.len == 0;
    }
};

/// Checks the exported tree against the manifest in both directions.
///
/// The second direction is the one that matters: a manifest lists what must be there,
/// and a directory listing shows what is. An export that copied an extra file is
/// wrong even though every declared file is correct.
pub fn verifyClosure(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    manifest: Manifest,
) Error!ClosureReport {
    var present: usize = 0;
    for (manifest.objects) |object| {
        const expected = digest.Digest.parse(object.digest) catch return error.InvalidManifest;
        var found_digest: [32]u8 = undefined;
        var buffer: [64 * 1024]u8 = undefined;
        var file = root.openFile(io, object.path, .{}) catch return error.DigestMismatch;
        defer file.close(io);
        var reader = file.reader(io, &buffer);
        const bytes = reader.interface.allocRemaining(gpa, .limited(64 * 1024 * 1024)) catch return error.DigestMismatch;
        defer gpa.free(bytes);
        std.crypto.hash.sha2.Sha256.hash(bytes, &found_digest, .{});
        if (!std.mem.eql(u8, &found_digest, &expected.bytes)) return error.DigestMismatch;
        present += 1;
    }

    var extra: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (extra.items) |path| gpa.free(path);
        extra.deinit(gpa);
    }
    try collect(gpa, io, root, "", manifest, &extra);
    return .{ .present = present, .extra = try extra.toOwnedSlice(gpa) };
}

fn collect(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    manifest: Manifest,
    extra: *std.ArrayList([]const u8),
) Error!void {
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        const path = if (prefix.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name });
        defer gpa.free(path);

        switch (entry.kind) {
            .directory => {
                const child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(io);
                try collect(gpa, io, child, path, manifest, extra);
            },
            .file => {
                var named = false;
                for (manifest.objects) |object| {
                    if (std.mem.eql(u8, object.path, path)) {
                        named = true;
                        break;
                    }
                }
                if (!named) try extra.append(gpa, try gpa.dupe(u8, path));
            },
            else => try extra.append(gpa, try gpa.dupe(u8, path)),
        }
    }
}

pub const RunResult = struct {
    exit_code: u8,
    output: []u8,

    pub fn deinit(self: RunResult, gpa: std.mem.Allocator) void {
        gpa.free(self.output);
    }
};

/// Runs the exported entry point, which is what makes the rootfs a program's home
/// rather than a directory of files.
pub fn runEntryPoint(
    gpa: std.mem.Allocator,
    io: std.Io,
    root_path: []const u8,
    manifest: Manifest,
) Error!RunResult {
    const absolute = std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_path, manifest.entry_point }) catch
        return error.OutOfMemory;
    defer gpa.free(absolute);

    var child = std.process.spawn(io, .{
        .argv = &.{absolute},
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.EntryPointFailed;
    defer child.kill(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    const output = stdout_reader.interface.allocRemaining(gpa, .limited(64 * 1024)) catch
        return error.EntryPointFailed;
    errdefer gpa.free(output);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buffer);
    const stderr = stderr_reader.interface.allocRemaining(gpa, .limited(64 * 1024)) catch
        return error.EntryPointFailed;
    defer gpa.free(stderr);

    const term = child.wait(io) catch return error.EntryPointFailed;
    const code: u8 = switch (term) {
        .exited => |value| value,
        else => return error.EntryPointFailed,
    };
    return .{ .exit_code = code, .output = output };
}

test "m15/IMAGE-004 build root filesystem: exported filesystem passes closure and entry-point tests" {
    std.debug.print("JCKG_EVIDENCE IMAGE-004\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const store_path = "zig-out/jckg-image-004-store";
    const root_path = "zig-out/jckg-image-004-root";
    cwd.deleteTree(io, store_path) catch {};
    cwd.deleteTree(io, root_path) catch {};
    defer cwd.deleteTree(io, store_path) catch {};
    defer cwd.deleteTree(io, root_path) catch {};

    var store_root = try cwd.createDirPathOpen(io, store_path, .{});
    defer store_root.close(io);
    const store = store_module.Store.init(io, gpa, store_root);
    try store.ensureLayout();

    // A real program and the data it reads, both in the store.
    const program = "#!/bin/sh\necho jckg-rootfs-ok\n";
    const data = "runtime data\n";
    const program_digest = try store.importBytes(program, null);
    const data_digest = try store.importBytes(data, null);
    var program_buffer: [digest.Digest.text_length]u8 = undefined;
    var data_buffer: [digest.Digest.text_length]u8 = undefined;
    const program_text = try gpa.dupe(u8, program_digest.text(&program_buffer));
    defer gpa.free(program_text);
    const data_text = try gpa.dupe(u8, data_digest.text(&data_buffer));
    defer gpa.free(data_text);

    const objects = [_]Object{
        .{ .path = "bin/jckg", .digest = program_text, .executable = true },
        .{ .path = "share/jckg/data", .digest = data_text },
    };
    const manifest = Manifest{ .name = "jckg-rootfs", .entry_point = "bin/jckg", .objects = &objects };

    var root = try cwd.createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    const exported = try exportRootfs(gpa, io, store, root, manifest);
    defer exported.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), exported.files);
    try std.testing.expectEqual(@as(u64, program.len + data.len), exported.total_bytes);

    // Closure, both directions: everything declared is present with its digest, and
    // nothing undeclared is.
    const closure = try verifyClosure(gpa, io, root, manifest);
    defer closure.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), closure.present);
    try std.testing.expect(closure.ok());

    // An extra file in the tree is reported: the manifest lists what must be there,
    // and a directory listing shows what is.
    try root.writeFile(io, .{ .sub_path = "share/jckg/scratch", .data = "leftovers\n" });
    const with_extra = try verifyClosure(gpa, io, root, manifest);
    defer with_extra.deinit(gpa);
    try std.testing.expect(!with_extra.ok());
    try std.testing.expectEqual(@as(usize, 1), with_extra.extra.len);
    try std.testing.expectEqualStrings("share/jckg/scratch", with_extra.extra[0]);
    root.deleteFile(io, "share/jckg/scratch") catch {};

    // A file whose bytes were changed after the export is caught by the digest rather
    // than by its name.
    try root.writeFile(io, .{ .sub_path = "share/jckg/data", .data = "tampered\n" });
    try std.testing.expectError(error.DigestMismatch, verifyClosure(gpa, io, root, manifest));
    // Put it back, and confirm the tree is whole again.
    const stored = try store.readBlobAlloc(gpa, data_digest);
    defer gpa.free(stored);
    try root.writeFile(io, .{ .sub_path = "share/jckg/data", .data = stored });

    // The entry point runs, from the exported tree, and its output is the program's.
    const run = try runEntryPoint(gpa, io, root_path, manifest);
    defer run.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), run.exit_code);
    try std.testing.expectEqualStrings("jckg-rootfs-ok\n", run.output);

    // A manifest whose entry point is not marked executable is refused before the
    // export: an entry point that cannot be executed is not one.
    const not_executable = [_]Object{.{ .path = "bin/jckg", .digest = program_text }};
    try std.testing.expectError(
        error.EntryPointNotExecutable,
        exportRootfs(gpa, io, store, root, .{ .name = "x", .entry_point = "bin/jckg", .objects = &not_executable }),
    );
    // An entry point the manifest does not contain is refused too.
    try std.testing.expectError(
        error.MissingEntryPoint,
        exportRootfs(gpa, io, store, root, .{ .name = "x", .entry_point = "bin/absent", .objects = &objects }),
    );
    // An object that is not in the store cannot be exported.
    const absent = [_]Object{.{ .path = "bin/x", .digest = "sha256:9999999999999999999999999999999999999999999999999999999999999999", .executable = true }};
    try std.testing.expectError(
        error.UnknownObject,
        exportRootfs(gpa, io, store, root, .{ .name = "x", .entry_point = "bin/x", .objects = &absent }),
    );

    // Paths that escape the destination, or are absolute, are refused: an export
    // writes into a directory, and a path that leaves it writes somewhere nobody
    // asked for.
    try std.testing.expect(!validPath("../bin/jckg"));
    try std.testing.expect(!validPath("bin/../../etc/passwd"));
    try std.testing.expect(!validPath("/bin/jckg"));
    try std.testing.expect(!validPath("bin/./jckg"));
    try std.testing.expect(!validPath(""));
    try std.testing.expect(validPath("bin/jckg"));
    try std.testing.expect(validPath("share/jckg/data"));
    const escaping = [_]Object{.{ .path = "../escape", .digest = program_text, .executable = true }};
    try std.testing.expectError(
        error.InvalidPath,
        exportRootfs(gpa, io, store, root, .{ .name = "x", .entry_point = "../escape", .objects = &escaping }),
    );
    // Two objects at one path would make the export ambiguous.
    const duplicated = [_]Object{ objects[0], .{ .path = "bin/jckg", .digest = data_text, .executable = true } };
    try std.testing.expectError(
        error.InvalidManifest,
        exportRootfs(gpa, io, store, root, .{ .name = "x", .entry_point = "bin/jckg", .objects = &duplicated }),
    );
}
