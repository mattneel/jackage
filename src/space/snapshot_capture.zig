//! Capturing a snapshot only when its bytes are stable (M12, SPACE-007).
//!
//! A snapshot is metadata about bytes: a digest, a length, and a path. If a file
//! changes while it is being read, that metadata describes a state the file was
//! never in - and a build that trusts it produces artifacts nobody can reproduce.
//!
//! This module reads each file, reads it again, and compares. A file that changed
//! between the two reads is retried, because a single write during capture is
//! ordinary; a file that keeps changing past the retry budget is reported as
//! **unstable**, with its path, because at that point the honest answer is that the
//! capture cannot describe the tree rather than a digest that describes nothing.
//!
//! The source is an interface, not a directory: the retry and instability rules are
//! what the case is about, and they are tested by a source that changes on cue
//! rather than by racing a real writer and hoping.
const std = @import("std");

pub const Error = error{
    SourceFailed,
    InvalidCapture,
    OutOfMemory,
    WriteFailed,
};

/// One file as the source sees it, with the facts a snapshot records.
pub const Snapshot = struct {
    path: []const u8,
    digest: [32]u8,
    byte_length: u64,
};

/// How the bytes are obtained. A filesystem implementation is provided; a test can
/// supply one that changes between reads, which makes the retry rules decidable.
pub const Source = struct {
    context: *anyopaque,
    /// Reads one file's bytes. The caller owns the returned slice.
    read: *const fn (context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) Error![]u8,
};

pub const Options = struct {
    /// How many times a changing file is re-read before the capture is reported as
    /// unstable. One retry absorbs an ordinary write; more absorbs a burst.
    max_retries: usize = 3,
};

pub const Instability = struct {
    /// The file that would not hold still.
    path: []const u8,
    /// How many times it was read before giving up.
    attempts: usize,
};

pub const Outcome = union(enum) {
    /// Every file held still; the metadata describes the tree.
    stable: []Snapshot,
    /// A file kept changing, so no metadata was committed for it.
    unstable: Instability,

    pub fn deinit(self: Outcome, gpa: std.mem.Allocator) void {
        switch (self) {
            .stable => |snapshots| {
                for (snapshots) |snapshot| gpa.free(snapshot.path);
                gpa.free(snapshots);
            },
            .unstable => |unstable| gpa.free(unstable.path),
        }
    }
};

fn digestOf(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// Captures the listed paths, retrying any that change and reporting the one that
/// will not hold still.
pub fn capture(
    gpa: std.mem.Allocator,
    source: Source,
    paths: []const []const u8,
    options: Options,
) Error!Outcome {
    if (options.max_retries == 0) return error.InvalidCapture;

    var snapshots: std.ArrayList(Snapshot) = .empty;
    errdefer {
        for (snapshots.items) |snapshot| gpa.free(snapshot.path);
        snapshots.deinit(gpa);
    }

    for (paths) |path| {
        var attempt: usize = 0;
        while (true) {
            attempt += 1;
            const first = try source.read(source.context, gpa, path);
            defer gpa.free(first);
            const second = try source.read(source.context, gpa, path);
            defer gpa.free(second);

            // Equality of the two reads is the whole test: it says the bytes did not
            // change between them, which is the only claim a snapshot can make.
            if (std.mem.eql(u8, first, second)) {
                try snapshots.append(gpa, .{
                    .path = try gpa.dupe(u8, path),
                    .digest = digestOf(second),
                    .byte_length = second.len,
                });
                break;
            }
            if (attempt > options.max_retries) {
                // No snapshot is committed for this path, and the caller is told
                // which file would not hold still rather than given a digest of
                // whichever read happened to be last.
                for (snapshots.items) |snapshot| gpa.free(snapshot.path);
                snapshots.deinit(gpa);
                return .{ .unstable = .{ .path = try gpa.dupe(u8, path), .attempts = attempt } };
            }
        }
    }
    return .{ .stable = try snapshots.toOwnedSlice(gpa) };
}

/// A filesystem-backed source: reads the file the ordinary way.
pub const FileSource = struct {
    dir: std.Io.Dir,
    io: std.Io,

    pub fn source(self: *FileSource) Source {
        return .{ .context = self, .read = readFile };
    }

    fn readFile(context: *anyopaque, gpa: std.mem.Allocator, path: []const u8) Error![]u8 {
        const self: *FileSource = @ptrCast(@alignCast(context));
        return self.dir.readFileAlloc(self.io, path, gpa, .limited(256 * 1024 * 1024)) catch return error.SourceFailed;
    }
};

test "m12/SPACE-007 snapshot stable bytes: a changing file is retried, then reported" {
    std.debug.print("JCKG_EVIDENCE SPACE-007\n", .{});
    const gpa = std.testing.allocator;

    // A scripted source: the same bytes every read, then bytes that change on the
    // first pair of reads and hold still afterwards, then bytes that never settle.
    const Script = struct {
        stable: []const u8,
        changing: []const u8,
        reads: usize = 0,
        /// Reads before the changing file settles; 0 means it never settles.
        settle_after: usize = 0,

        fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.reads += 1;
            if (std.mem.eql(u8, path, "stable.txt")) return allocator.dupe(u8, self.stable);
            const settled = self.settle_after > 0 and self.reads > self.settle_after;
            if (settled) return allocator.dupe(u8, self.stable);
            var text = try allocator.dupe(u8, self.changing);
            text[0] = 'A' + @as(u8, @intCast(self.reads % 26));
            return text;
        }
    };
    _ = &Script.read;

    // A stable tree captures with one pair of reads per file.
    var stable_source = Script{ .stable = "payload\n", .changing = "payload\n" };
    const source = Source{ .context = &stable_source, .read = Script.read };
    const stable = try capture(gpa, source, &.{"stable.txt"}, .{});
    defer stable.deinit(gpa);
    switch (stable) {
        .stable => |snapshots| {
            try std.testing.expectEqual(@as(usize, 1), snapshots.len);
            try std.testing.expectEqualStrings("stable.txt", snapshots[0].path);
            try std.testing.expectEqual(@as(u64, 8), snapshots[0].byte_length);
            try std.testing.expectEqual(@as(usize, 2), stable_source.reads);
        },
        .unstable => return error.TestUnexpectedResult,
    }

    // A file that changes once and then settles is retried until it holds still; the
    // snapshot that comes out describes the settled bytes.
    var settling_source = Script{ .stable = "settled\n", .changing = "changing\n", .settle_after = 2 };
    const settling = Source{ .context = &settling_source, .read = Script.read };
    const recovered = try capture(gpa, settling, &.{"changing.txt"}, .{});
    defer recovered.deinit(gpa);
    switch (recovered) {
        .stable => |snapshots| {
            try std.testing.expectEqual(@as(usize, 1), snapshots.len);
            try std.testing.expectEqual(@as(u64, 8), snapshots[0].byte_length);
            // It took at least two attempts: the first pair disagreed.
            try std.testing.expect(settling_source.reads >= 4);
        },
        .unstable => return error.TestUnexpectedResult,
    }

    // A file that never settles is reported as unstable, with its path, and no
    // metadata is committed for it at all.
    var racing_source = Script{ .stable = "settled\n", .changing = "never-settles\n", .settle_after = 0 };
    const racing = Source{ .context = &racing_source, .read = Script.read };
    const outcome = try capture(gpa, racing, &.{"racing.txt"}, .{ .max_retries = 3 });
    defer outcome.deinit(gpa);
    switch (outcome) {
        .unstable => |unstable| {
            try std.testing.expectEqualStrings("racing.txt", unstable.path);
            // Retries happened, and the attempt count says how many.
            try std.testing.expectEqual(@as(usize, 4), unstable.attempts);
            try std.testing.expectEqual(@as(usize, 8), racing_source.reads);
        },
        .stable => return error.TestUnexpectedResult,
    }

    // A zero retry budget is refused: "retry or report" needs somewhere to retry.
    try std.testing.expectError(error.InvalidCapture, capture(gpa, source, &.{"stable.txt"}, .{ .max_retries = 0 }));

    // The filesystem source is exercised for real as well, so the ordinary path is
    // not merely assumed to work.
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root_path = "zig-out/jckg-space-007";
    cwd.deleteTree(io, root_path) catch {};
    defer cwd.deleteTree(io, root_path) catch {};
    var root = try cwd.createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    try root.writeFile(io, .{ .sub_path = "real.txt", .data = "real bytes\n" });
    var file_source = FileSource{ .dir = root, .io = io };
    const real = try capture(gpa, file_source.source(), &.{"real.txt"}, .{});
    defer real.deinit(gpa);
    switch (real) {
        .stable => |snapshots| {
            try std.testing.expectEqual(@as(usize, 1), snapshots.len);
            try std.testing.expectEqual(@as(u64, 11), snapshots[0].byte_length);
        },
        .unstable => return error.TestUnexpectedResult,
    }
}
