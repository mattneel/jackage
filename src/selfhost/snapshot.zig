//! Source snapshots for self-hosted builds (M09, SELF-007).
//!
//! A Linux self-hosted build must not require an independently maintained `~/src`
//! checkout: it consumes a *snapshot* of the primary checkout, taken on the host
//! side and materialized on the executor's own storage. Two properties make that
//! safe, and both are checked here rather than assumed:
//!
//! - **The snapshot is complete for its purpose.** The plan names what is copied:
//!   source, build definitions, scripts, and the declared vendored sources. What a
//!   build can regenerate - caches, build outputs, and working directories - is
//!   excluded on purpose, so the snapshot is small and reproducible rather than a
//!   copy of whatever the primary checkout happened to accumulate.
//! - **The snapshot is verified after it lands.** Every file is digested on both
//!   sides and compared, so a truncated transfer, a line-ending translation, or a
//!   file that never arrived is a failure with the path named - not a build that
//!   fails later for an unrelated-looking reason.
const std = @import("std");

/// The failures this module raises on its own. The I/O error sets are inferred, so
/// the module does not have to restate (and can not accidentally misstate) what the
/// standard library already declares.
pub const Error = error{
    SnapshotMissing,
    SnapshotMismatch,
    SnapshotIncomplete,
    WriteFailed,
};

/// One entry in the plan: a path copied from the primary checkout into the
/// snapshot, at the same relative location.
pub const Entry = struct {
    path: []const u8,
    kind: std.Io.File.Kind,
};

/// Names that are never part of a snapshot. They are caches, build outputs, or
/// working state: a build regenerates them, and copying them would make the
/// snapshot depend on what the primary checkout happened to have done.
pub const excluded_names = [_][]const u8{
    ".zig-cache",
    ".zig-cache-strict",
    "zig-cache",
    "zig-out",
    ".git",
    "node_modules",
    ".jckg-workspaces",
};

/// True when a path component excludes its whole subtree from a snapshot.
pub fn excluded(component: []const u8) bool {
    for (excluded_names) |name| {
        if (std.mem.eql(u8, component, name)) return true;
    }
    return false;
}

/// Builds the plan for a snapshot: every file under `dir`, recursively, minus the
/// excluded subtrees. Directory entries are included so empty-but-declared
/// directories survive the copy.
pub fn planFrom(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    prefix: []const u8,
) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| gpa.free(entry.path);
        entries.deinit(gpa);
    }

    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (excluded(entry.name)) continue;
        // Portable separators on purpose: a snapshot is taken on the host and
        // consumed by an executor, so its entry paths must mean the same thing on
        // both sides. `std.fs.path.join` would produce `src\\main.zig` on Windows
        // and the two sides would never agree.
        const path = if (prefix.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name });
        errdefer gpa.free(path);

        switch (entry.kind) {
            .directory => {
                try entries.append(gpa, .{ .path = path, .kind = .directory });
                const child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(io);
                const nested = try planFrom(io, gpa, child, path);
                // The nested plan owns its own path strings; freeing only the slice
                // would leak every one of them.
                defer deinitPlan(gpa, nested);
                for (nested) |nested_entry| {
                    try entries.append(gpa, .{ .path = try gpa.dupe(u8, nested_entry.path), .kind = nested_entry.kind });
                }
            },
            .file => try entries.append(gpa, .{ .path = path, .kind = .file }),
            // Symlinks and special files are not part of a source snapshot: the
            // snapshot is a copy, and a copied symlink points somewhere else.
            else => gpa.free(path),
        }
    }
    return entries.toOwnedSlice(gpa);
}

pub fn deinitPlan(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| gpa.free(entry.path);
    gpa.free(entries);
}

fn digestOf(io: std.Io, dir: std.Io.Dir, path: []const u8) ![64]u8 {
    const file = dir.openFile(io, path, .{}) catch return error.SnapshotIncomplete;
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    while (true) {
        const read = reader.interface.readSliceShort(&buffer) catch return error.SnapshotIncomplete;
        if (read == 0) break;
        hasher.update(buffer[0..read]);
    }
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

pub const Report = struct {
    compared: usize,
    /// The first file whose bytes differ, when one did.
    mismatch: ?[]const u8,
    /// The first planned file that is missing from the snapshot, when one is.
    missing: ?[]const u8,

    pub fn ok(self: Report) bool {
        return self.mismatch == null and self.missing == null;
    }
};

/// Compares a materialized snapshot against the primary checkout entry by entry.
///
/// This is what lets a Linux build consume a snapshot instead of an independently
/// maintained checkout: the bytes are proven equal, path by path, before the build
/// is allowed to start.
pub fn verify(
    io: std.Io,
    gpa: std.mem.Allocator,
    source: std.Io.Dir,
    snapshot: std.Io.Dir,
    entries: []const Entry,
) !Report {
    _ = gpa;
    var report = Report{ .compared = 0, .mismatch = null, .missing = null };
    for (entries) |entry| {
        if (entry.kind != .file) continue;
        const source_digest = digestOf(io, source, entry.path) catch {
            report.missing = entry.path;
            return report;
        };
        const snapshot_digest = digestOf(io, snapshot, entry.path) catch {
            report.missing = entry.path;
            return report;
        };
        report.compared += 1;
        if (!std.mem.eql(u8, &source_digest, &snapshot_digest)) {
            report.mismatch = entry.path;
            return report;
        }
    }
    return report;
}

/// Copies the planned entries from `source` into `snapshot`, creating directories
/// as needed. Excluded subtrees never reach here because the plan omits them.
pub fn materialize(
    io: std.Io,
    source: std.Io.Dir,
    snapshot: std.Io.Dir,
    entries: []const Entry,
) !void {
    for (entries) |entry| {
        switch (entry.kind) {
            .directory => snapshot.createDirPath(io, entry.path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            },
            .file => {
                if (std.fs.path.dirname(entry.path)) |parent| {
                    snapshot.createDirPath(io, parent) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                }
                var source_file = try source.openFile(io, entry.path, .{});
                defer source_file.close(io);
                var destination = try snapshot.createFile(io, entry.path, .{ .truncate = true });
                defer destination.close(io);
                var buffer: [64 * 1024]u8 = undefined;
                var write_buffer: [64 * 1024]u8 = undefined;
                var writer = destination.writer(io, &write_buffer);
                var reader = source_file.reader(io, &buffer);
                while (true) {
                    const read = reader.interface.readSliceShort(&buffer) catch break;
                    if (read == 0) break;
                    writer.interface.writeAll(buffer[0..read]) catch return error.WriteFailed;
                }
                writer.interface.flush() catch return error.WriteFailed;
            },
            else => {},
        }
    }
}

test "m09/SELF-007 preserve primary source: a snapshot is complete and verified" {
    std.debug.print("JCKG_EVIDENCE SELF-007\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const source_path = "zig-out/jckg-snapshot-source";
    const snapshot_path = "zig-out/jckg-snapshot-copy";
    cwd.deleteTree(io, source_path) catch {};
    cwd.deleteTree(io, snapshot_path) catch {};
    defer cwd.deleteTree(io, source_path) catch {};
    defer cwd.deleteTree(io, snapshot_path) catch {};

    var source = try cwd.createDirPathOpen(io, source_path, .{ .open_options = .{ .iterate = true } });
    defer source.close(io);
    try source.createDirPath(io, "src");
    try source.writeFile(io, .{ .sub_path = "src/main.zig", .data = "// source file\n" });
    try source.writeFile(io, .{ .sub_path = "build.zig", .data = "// build definition\n" });
    // A cache and a build output: present in the primary checkout, never in a
    // snapshot, because a build regenerates them and copying them would make the
    // snapshot depend on what this checkout happened to do.
    try source.createDirPath(io, ".zig-cache");
    try source.writeFile(io, .{ .sub_path = ".zig-cache/artifact", .data = "cache bytes\n" });
    try source.createDirPath(io, "zig-out");
    try source.writeFile(io, .{ .sub_path = "zig-out/jckg", .data = "build output\n" });

    var snapshot = try cwd.createDirPathOpen(io, snapshot_path, .{ .open_options = .{ .iterate = true } });
    defer snapshot.close(io);

    const plan = try planFrom(io, gpa, source, "");
    defer deinitPlan(gpa, plan);

    // The plan names the source and the build definition, and excludes the cache
    // and the build output entirely - not merely at the top level.
    var saw_source = false;
    var saw_build = false;
    for (plan) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.path, ".zig-cache"));
        try std.testing.expect(!std.mem.startsWith(u8, entry.path, "zig-out"));
        if (std.mem.eql(u8, entry.path, "src/main.zig")) saw_source = true;
        if (std.mem.eql(u8, entry.path, "build.zig")) saw_build = true;
    }
    try std.testing.expect(saw_source and saw_build);

    try materialize(io, source, snapshot, plan);
    const report = try verify(io, gpa, source, snapshot, plan);
    try std.testing.expect(report.ok());
    try std.testing.expect(report.compared >= 2);

    // Negative-or-recovery: a snapshot whose bytes differ is reported with the
    // path, so a translation or a truncated transfer is named rather than left to
    // surface as an unrelated build error later.
    try snapshot.writeFile(io, .{ .sub_path = "src/main.zig", .data = "// source file\n// injected\n" });
    const broken = try verify(io, gpa, source, snapshot, plan);
    try std.testing.expect(!broken.ok());
    try std.testing.expect(broken.mismatch != null);
    try std.testing.expectEqualStrings("src/main.zig", broken.mismatch.?);
}
