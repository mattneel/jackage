//! Bringing guest edits home without overwriting the host (M12, SPACE-009).
//!
//! A guest exports edits that were made from some revision of the host's files. By
//! the time they arrive the host may have moved. The three-way comparison below is
//! the whole of the decision:
//!
//! - the host still matches what the guest started from - the edit applies;
//! - the host changed and the guest did not - the host is already ahead;
//! - both changed the same way - there is nothing to do;
//! - both changed differently - **divergence**, reported with both digests, and the
//!   host file is not written.
//!
//! The last case is the one that matters. Overwriting there would destroy work that
//! exists nowhere else, and a "prefer the newer one" rule is a coin flip dressed as
//! a policy. Divergence is therefore a result, not an error: the caller decides, and
//! the record says what decided.
//!
//! A path the host removed while the guest modified it is divergence too. Recreating
//! it silently would undo a deletion the user made deliberately.
const std = @import("std");
const digest = @import("../core/digest.zig");

pub const Error = error{
    InvalidEntry,
    WriteFailed,
    OutOfMemory,
};

pub const Base = struct {
    path: []const u8,
    /// The digest of the revision the guest's edits were made from.
    digest: []const u8,
};

pub const Export = struct {
    path: []const u8,
    /// The guest's bytes. Absent means the guest deleted the file.
    data: ?[]const u8,
};

pub const Status = enum {
    /// The guest's edit was written to the host.
    applied,
    /// The host already contains this change; nothing was written.
    already_present,
    /// Both sides changed the same file differently; nothing was written.
    divergent,
    /// The host has no such file and the base has none either.
    added,
    /// The guest deleted a file the host has not changed; the deletion was applied.
    removed,
};

pub const Result = struct {
    path: []const u8,
    status: Status,
    /// The digest the guest started from, for a divergent path.
    base_digest: []const u8,
    /// The host's digest now, for a divergent path, or null when the host file is
    /// gone.
    host_digest: ?[]const u8,
    /// The digest of what the guest tried to write, for a divergent path.
    guest_digest: ?[]const u8,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.base_digest);
        if (self.host_digest) |value| gpa.free(value);
        if (self.guest_digest) |value| gpa.free(value);
    }
};

pub const Report = struct {
    results: []Result,

    pub fn deinit(self: Report, gpa: std.mem.Allocator) void {
        for (self.results) |result| result.deinit(gpa);
        gpa.free(self.results);
    }

    pub fn statusFor(self: Report, path: []const u8) ?Status {
        for (self.results) |result| {
            if (std.mem.eql(u8, result.path, path)) return result.status;
        }
        return null;
    }

};

fn digestText(gpa: std.mem.Allocator, data: []const u8) Error![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &raw, .{});
    return std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(raw, .lower)});
}

fn readIfPresent(io: std.Io, root: std.Io.Dir, path: []const u8, gpa: std.mem.Allocator) Error!?[]u8 {
    const file = root.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.InvalidEntry,
    };
    defer file.close(io);
    var buffer = try std.ArrayList(u8).initCapacity(gpa, 4096);
    errdefer buffer.deinit(gpa);
    var scratch: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &scratch);
    while (true) {
        const read = reader.interface.readSliceShort(&scratch) catch return error.InvalidEntry;
        if (read == 0) break;
        try buffer.appendSlice(gpa, scratch[0..read]);
    }
    const slice = try buffer.toOwnedSlice(gpa);
    return slice;
}

pub const Reconciliation = struct {
    written: usize,
    removed: usize,
};

/// Reconciles guest exports against the host directory, writing only where the
/// three-way comparison says the guest's edit is the change the host does not have.
pub fn reconcile(
    io: std.Io,
    gpa: std.mem.Allocator,
    host: std.Io.Dir,
    bases: []const Base,
    exports: []const Export,
) Error!struct { report: Report, stats: Reconciliation } {
    var results: std.ArrayList(Result) = .empty;
    errdefer {
        for (results.items) |result| result.deinit(gpa);
        results.deinit(gpa);
    }
    var stats = Reconciliation{ .written = 0, .removed = 0 };

    for (exports) |incoming| {
        var base_digest: []const u8 = "";
        var have_base = false;
        for (bases) |base| {
            if (std.mem.eql(u8, base.path, incoming.path)) {
                base_digest = base.digest;
                have_base = true;
                break;
            }
        }
        if (have_base) _ = digest.Digest.parse(base_digest) catch return error.InvalidEntry;
        const base_owned = try gpa.dupe(u8, base_digest);

        const host_data = try readIfPresent(io, host, incoming.path, gpa);
        defer if (host_data) |data| gpa.free(data);
        const host_text: ?[]u8 = if (host_data) |data|
            try digestText(gpa, data)
        else
            null;
        defer if (host_text) |text| gpa.free(text);

        const guest_text: ?[]u8 = if (incoming.data) |data|
            try digestText(gpa, data)
        else
            null;
        defer if (guest_text) |text| gpa.free(text);

        const host_matches_base = if (host_text) |text|
            std.mem.eql(u8, text, base_digest)
        else
            false;
        const guest_matches_base = if (guest_text) |text|
            std.mem.eql(u8, text, base_digest)
        else
            false;
        const guest_matches_host = if (host_text) |host_value|
            if (guest_text) |guest_value| std.mem.eql(u8, host_value, guest_value) else false
        else
            guest_text == null;

        var status: Status = undefined;
        if (!have_base) {
            // No base revision: the path is new. It applies when the host does not
            // have it either, and is divergence when both sides produced a file at
            // the same path without a common starting point.
            if (host_data == null) {
                if (incoming.data) |data| {
                    if (std.fs.path.dirname(incoming.path)) |parent| {
                        host.createDirPath(io, parent) catch {};
                    }
                    const file = host.createFile(io, incoming.path, .{ .truncate = true }) catch return error.WriteFailed;
                    defer file.close(io);
                    var scratch: [16 * 1024]u8 = undefined;
                    var writer = file.writer(io, &scratch);
                    writer.interface.writeAll(data) catch return error.WriteFailed;
                    writer.interface.flush() catch return error.WriteFailed;
                    stats.written += 1;
                    status = .added;
                } else {
                    // The guest sends nothing for a path that never existed.
                    status = .already_present;
                }
            } else {
                status = .divergent;
            }
            try results.append(gpa, .{
                .path = try gpa.dupe(u8, incoming.path),
                .status = status,
                .base_digest = base_owned,
                .host_digest = if (host_text) |text| try gpa.dupe(u8, text) else null,
                .guest_digest = if (guest_text) |text| try gpa.dupe(u8, text) else null,
            });
            continue;
        }
        if (guest_matches_host) {
            status = .already_present;
        } else if (guest_matches_base) {
            // The guest sends back what it started from: the host's version stands.
            status = .already_present;
        } else if (host_matches_base) {
            // The host is untouched since the guest started: the edit applies.
            if (incoming.data) |data| {
                if (std.fs.path.dirname(incoming.path)) |parent| {
                    host.createDirPath(io, parent) catch {};
                }
                const file = host.createFile(io, incoming.path, .{ .truncate = true }) catch return error.WriteFailed;
                defer file.close(io);
                var scratch: [16 * 1024]u8 = undefined;
                var writer = file.writer(io, &scratch);
                writer.interface.writeAll(data) catch return error.WriteFailed;
                writer.interface.flush() catch return error.WriteFailed;
                stats.written += 1;
                status = .applied;
            } else {
                host.deleteFile(io, incoming.path) catch return error.WriteFailed;
                stats.removed += 1;
                status = .removed;
            }
        } else {
            // Both sides changed the same file, differently. Nothing is written, and
            // both digests travel with the result so the decision can be made by a
            // person who can see what they are choosing between.
            status = .divergent;
        }

        try results.append(gpa, .{
            .path = try gpa.dupe(u8, incoming.path),
            .status = status,
            .base_digest = base_owned,
            .host_digest = if (host_text) |text| try gpa.dupe(u8, text) else null,
            .guest_digest = if (guest_text) |text| try gpa.dupe(u8, text) else null,
        });
    }
    return .{ .report = .{ .results = try results.toOwnedSlice(gpa) }, .stats = stats };
}

test "m12/SPACE-009 protect host edits: divergence is reported and the host is not overwritten" {
    std.debug.print("JCKG_EVIDENCE SPACE-009\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const root_path = "zig-out/jckg-space-009";
    cwd.deleteTree(io, root_path) catch {};
    defer cwd.deleteTree(io, root_path) catch {};
    var host = try cwd.createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer host.close(io);

    const base_bytes = "base line\n";
    var base_buffer: [71]u8 = undefined;
    const base_digest: []const u8 = blk: {
        var raw: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(base_bytes, &raw, .{});
        break :blk try std.fmt.bufPrint(&base_buffer, "sha256:{s}", .{std.fmt.bytesToHex(raw, .lower)});
    };

    // Applied: the host still matches the base.
    try host.writeFile(io, .{ .sub_path = "applied.zig", .data = base_bytes });
    // Divergent: the host moved since the guest started.
    try host.writeFile(io, .{ .sub_path = "divergent.zig", .data = "host change\n" });
    // Gone on the host, modified by the guest: divergence, not a silent recreation.
    // Already present: both sides made the same change.
    try host.writeFile(io, .{ .sub_path = "agreed.zig", .data = "same change\n" });
    // Deleted by the guest, untouched on the host: the deletion applies.
    try host.writeFile(io, .{ .sub_path = "removed.zig", .data = base_bytes });
    // New in the guest and absent on the host: applied.
    // New on both sides with no common base: divergence.
    try host.writeFile(io, .{ .sub_path = "both-new.zig", .data = "host new\n" });

    const bases = [_]Base{
        .{ .path = "applied.zig", .digest = base_digest },
        .{ .path = "divergent.zig", .digest = base_digest },
        .{ .path = "gone.zig", .digest = base_digest },
        .{ .path = "agreed.zig", .digest = base_digest },
        .{ .path = "removed.zig", .digest = base_digest },
        .{ .path = "both-new.zig", .digest = base_digest },
    };
    const exports = [_]Export{
        .{ .path = "applied.zig", .data = "guest edit\n" },
        .{ .path = "divergent.zig", .data = "guest change\n" },
        .{ .path = "gone.zig", .data = "guest edit\n" },
        .{ .path = "agreed.zig", .data = "same change\n" },
        .{ .path = "removed.zig", .data = null },
        .{ .path = "both-new.zig", .data = "guest new\n" },
        .{ .path = "added.zig", .data = "brand new\n" },
    };

    const outcome = try reconcile(io, gpa, host, &bases, &exports);
    defer outcome.report.deinit(gpa);

    // Each path lands in exactly the state the comparison implies.
    try std.testing.expectEqual(Status.applied, outcome.report.statusFor("applied.zig").?);
    try std.testing.expectEqual(Status.divergent, outcome.report.statusFor("divergent.zig").?);
    try std.testing.expectEqual(Status.divergent, outcome.report.statusFor("gone.zig").?);
    try std.testing.expectEqual(Status.already_present, outcome.report.statusFor("agreed.zig").?);
    try std.testing.expectEqual(Status.removed, outcome.report.statusFor("removed.zig").?);
    // A file new in the guest applies; the same path new on both sides diverges,
    // because without a common base there is no way to tell an edit from a clobber.
    try std.testing.expectEqual(Status.added, outcome.report.statusFor("added.zig").?);
    try std.testing.expectEqual(Status.divergent, outcome.report.statusFor("both-new.zig").?);

    // Only the fast-forward cases were acted on.
    try std.testing.expectEqual(@as(usize, 2), outcome.stats.written);
    try std.testing.expectEqual(@as(usize, 1), outcome.stats.removed);

    // The host's divergent file still holds the host's bytes - the guest's version
    // was not written over work that exists nowhere else.
    const divergent_now = try readIfPresent(io, host, "divergent.zig", gpa);
    defer if (divergent_now) |data| gpa.free(data);
    try std.testing.expect(divergent_now != null);
    try std.testing.expectEqualStrings("host change\n", divergent_now.?);

    // A file the host removed is not recreated by the guest's edit.
    const gone_now = try readIfPresent(io, host, "gone.zig", gpa);
    defer if (gone_now) |data| gpa.free(data);
    try std.testing.expect(gone_now == null);

    // The applied file holds the guest's bytes, and the agreed file was not touched.
    const applied_now = try readIfPresent(io, host, "applied.zig", gpa);
    defer if (applied_now) |data| gpa.free(data);
    try std.testing.expectEqualStrings("guest edit\n", applied_now.?);
    const agreed_now = try readIfPresent(io, host, "agreed.zig", gpa);
    defer if (agreed_now) |data| gpa.free(data);
    try std.testing.expectEqualStrings("same change\n", agreed_now.?);
    // The guest's deletion landed.
    const removed_now = try readIfPresent(io, host, "removed.zig", gpa);
    try std.testing.expect(removed_now == null);

    // The file new on both sides still holds the host's bytes, and the file the
    // guest added exists.
    const both_now = try readIfPresent(io, host, "both-new.zig", gpa);
    defer if (both_now) |data| gpa.free(data);
    try std.testing.expectEqualStrings("host new\n", both_now.?);
    const added_now = try readIfPresent(io, host, "added.zig", gpa);
    defer if (added_now) |data| gpa.free(data);
    try std.testing.expectEqualStrings("brand new\n", added_now.?);

    // A divergent result carries both digests, because a person deciding between two
    // versions needs to know they are different and which is which.
    for (outcome.report.results) |result| {
        if (result.status != .divergent) continue;
        // The guest side always has bytes to describe; the host side may legitimately
        // be absent, when the host removed the file the guest edited.
        try std.testing.expect(result.guest_digest != null);
        if (result.host_digest) |host_value| {
            try std.testing.expect(!std.mem.eql(u8, host_value, result.guest_digest.?));
        }
    }

    // A base digest that is not a digest is refused: the comparison could not be
    // made honestly.
    const malformed = [_]Base{.{ .path = "applied.zig", .digest = "not-a-digest" }};
    const one_export = [_]Export{.{ .path = "applied.zig", .data = "x" }};
    try std.testing.expectError(error.InvalidEntry, reconcile(io, gpa, host, &malformed, &one_export));
}
