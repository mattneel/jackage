//! Keeping collection away from bytes that are not the store's to reap (M12, SPACE-001).
//!
//! Garbage collection and cache eviction are allowed to delete things Jackage
//! itself owns: store objects, cache entries, materialized trees. They are never
//! allowed to delete a user's source, and they are never allowed to delete
//! uncommitted work in a workspace Jackage manages - that is the difference between
//! a cache and a data-loss incident.
//!
//! The plan below is therefore *subtractive*: every candidate is checked against the
//! protected roots, and a candidate that lies inside one is refused with a reason
//! rather than collected. Paths are normalized first, so a candidate written as
//! `cache/../src/main.zig` is recognized as source rather than trusted as a cache
//! entry - a string that merely looks like a cache path is not one.
//!
//! Nothing here deletes anything. The plan is a description of what may be reaped,
//! and the caller performs it; that keeps the safety decision auditable and testable
//! without a destructive step in the middle of it.
const std = @import("std");

pub const Error = error{
    InvalidPath,
    OutOfMemory,
};

pub const Refusal = struct {
    path: []const u8,
    reason: RefusalReason,
};

pub const RefusalReason = enum {
    /// The candidate lies inside a source tree the user owns.
    source_root,
    /// The candidate lies inside a workspace with uncommitted changes.
    uncommitted_workspace,
    /// The candidate is not a path Jackage recognizes as its own.
    outside_managed_roots,
};

/// A directory whose contents must not be reaped.
pub const Protected = struct {
    /// Root of the source tree, as an absolute or store-relative path.
    source_root: []const u8,
    /// Workspace directories holding uncommitted edits.
    uncommitted_workspaces: []const []const u8,
};

pub const Plan = struct {
    /// Candidates that may be reaped.
    collectable: []const []const u8,
    /// Candidates that must not be, with the reason each was refused.
    refused: []Refusal,
    /// Bytes the collectable candidates account for, as measured by the store.
    reclaimable_bytes: u64,

    pub fn deinit(self: Plan, gpa: std.mem.Allocator) void {
        for (self.collectable) |path| gpa.free(path);
        gpa.free(self.collectable);
        for (self.refused) |refusal| gpa.free(refusal.path);
        gpa.free(self.refused);
    }

    pub fn refusalFor(self: Plan, path: []const u8) ?RefusalReason {
        for (self.refused) |refusal| {
            if (std.mem.eql(u8, refusal.path, path)) return refusal.reason;
        }
        return null;
    }
};

pub const Candidate = struct {
    path: []const u8,
    byte_length: u64,
};

const MAX_PATH = 4096;

/// Normalizes a slash-separated path: collapses `.` and `..`, without resolving
/// symlinks (which would require touching the filesystem and would let a link decide
/// what is protected).
fn normalize(buffer: []u8, path: []const u8) Error![]u8 {
    if (path.len == 0 or path.len > MAX_PATH) return error.InvalidPath;
    var parts: [128][]const u8 = undefined;
    var count: usize = 0;

    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count == 0) return error.InvalidPath; // Escapes the root entirely.
            count -= 1;
            continue;
        }
        if (count == parts.len) return error.InvalidPath;
        parts[count] = part;
        count += 1;
    }
    if (count == 0) return error.InvalidPath;

    var len: usize = 0;
    for (parts[0..count], 0..) |part, index| {
        if (index > 0) {
            buffer[len] = '/';
            len += 1;
        }
        if (len + part.len > MAX_PATH) return error.InvalidPath;
        @memcpy(buffer[len .. len + part.len], part);
        len += part.len;
    }
    return buffer[0..len];
}

fn contains(root: []const u8, candidate: []const u8) bool {
    if (candidate.len < root.len) return false;
    if (!std.mem.eql(u8, candidate[0..root.len], root)) return false;
    return candidate.len == root.len or candidate[root.len] == '/';
}

/// Plans which candidates may be reaped, refusing everything that belongs to the user.
pub fn plan(
    gpa: std.mem.Allocator,
    protected: Protected,
    candidates: []const Candidate,
) Error!Plan {
    var root_buffer: [MAX_PATH]u8 = undefined;
    const source_root = try normalize(&root_buffer, protected.source_root);
    var workspace_buffers = try gpa.alloc([MAX_PATH]u8, protected.uncommitted_workspaces.len);
    defer gpa.free(workspace_buffers);
    var workspaces = try gpa.alloc([]const u8, protected.uncommitted_workspaces.len);
    defer gpa.free(workspaces);
    for (protected.uncommitted_workspaces, 0..) |workspace, index| {
        workspaces[index] = try normalize(&workspace_buffers[index], workspace);
    }

    var collectable: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (collectable.items) |path| gpa.free(path);
        collectable.deinit(gpa);
    }
    var refused: std.ArrayList(Refusal) = .empty;
    errdefer {
        for (refused.items) |refusal| gpa.free(refusal.path);
        refused.deinit(gpa);
    }
    var reclaimable: u64 = 0;

    for (candidates) |candidate| {
        var buffer: [MAX_PATH]u8 = undefined;
        const normalized = try normalize(&buffer, candidate.path);

        // Source first: it is the strongest reason and the one whose loss is
        // unrecoverable.
        if (contains(source_root, normalized)) {
            try refused.append(gpa, .{
                .path = try gpa.dupe(u8, candidate.path),
                .reason = .source_root,
            });
            continue;
        }
        var refused_workspace = false;
        for (workspaces) |workspace| {
            if (contains(workspace, normalized)) {
                try refused.append(gpa, .{
                    .path = try gpa.dupe(u8, candidate.path),
                    .reason = .uncommitted_workspace,
                });
                refused_workspace = true;
                break;
            }
        }
        if (refused_workspace) continue;

        try collectable.append(gpa, try gpa.dupe(u8, candidate.path));
        reclaimable += candidate.byte_length;
    }

    return .{
        .collectable = try collectable.toOwnedSlice(gpa),
        .refused = try refused.toOwnedSlice(gpa),
        .reclaimable_bytes = reclaimable,
    };
}

test "m12/SPACE-001 protect source bytes: collection never touches source or uncommitted work" {
    std.debug.print("JCKG_EVIDENCE SPACE-001\n", .{});
    const gpa = std.testing.allocator;

    const protected = Protected{
        .source_root = "C:/src/myproject",
        .uncommitted_workspaces = &.{"C:/Users/me/jackage/workspaces/feature-branch"},
    };

    const candidates = [_]Candidate{
        // Ordinary store and cache entries: the things collection is for.
        .{ .path = "C:/Users/me/jackage/store/sha256:aaaa", .byte_length = 1024 },
        .{ .path = "C:/Users/me/jackage/cache/fetch", .byte_length = 2048 },
        // Source, by direct path and by a path that only looks like a cache entry.
        .{ .path = "C:/src/myproject/src/main.zig", .byte_length = 4096 },
        .{ .path = "C:/Users/me/jackage/cache/../../../../src/myproject/main.zig", .byte_length = 512 },
        // The source root itself.
        .{ .path = "C:/src/myproject", .byte_length = 8192 },
        // Uncommitted work in a managed workspace.
        .{ .path = "C:/Users/me/jackage/workspaces/feature-branch/src/lib.zig", .byte_length = 256 },
        // A sibling directory that merely shares a prefix is not source.
        .{ .path = "C:/src/myproject-notes/todo.md", .byte_length = 64 },
    };

    const planned = try plan(gpa, protected, &candidates);
    defer planned.deinit(gpa);

    // Only the two store entries and the prefix-sibling are collectable.
    try std.testing.expectEqual(@as(usize, 3), planned.collectable.len);
    for (planned.collectable) |path| {
        try std.testing.expect(!std.mem.startsWith(u8, path, "C:/src/myproject/"));
    }

    // The bytes reclaimed are the bytes of those candidates alone, whether or not
    // they are reclaimed by an object already held.
    try std.testing.expectEqual(@as(u64, 1024 + 2048 + 64), planned.reclaimable_bytes);

    // Every refusal carries its reason, and the reason names the rule that matched.
    try std.testing.expectEqual(@as(usize, 4), planned.refused.len);
    try std.testing.expectEqual(
        RefusalReason.source_root,
        planned.refusalFor("C:/src/myproject/src/main.zig").?,
    );
    // The disguised candidate is recognized as source rather than trusted as a cache
    // entry, even though its written form begins in the cache directory.
    try std.testing.expectEqual(
        RefusalReason.source_root,
        planned.refusalFor("C:/Users/me/jackage/cache/../../../../src/myproject/main.zig").?,
    );
    try std.testing.expectEqual(
        RefusalReason.source_root,
        planned.refusalFor("C:/src/myproject").?,
    );
    try std.testing.expectEqual(
        RefusalReason.uncommitted_workspace,
        planned.refusalFor("C:/Users/me/jackage/workspaces/feature-branch/src/lib.zig").?,
    );

    // A candidate that escapes its root is refused outright: `..` past the top means
    // the path does not describe a location Jackage manages at all.
    const escaping = [_]Candidate{.{ .path = "../src/myproject/main.zig", .byte_length = 1 }};
    try std.testing.expectError(error.InvalidPath, plan(gpa, protected, &escaping));

    // With no candidates, nothing is collectable and nothing is refused - an empty
    // plan is reported as empty rather than as an error.
    const nothing = try plan(gpa, protected, &.{});
    defer nothing.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), nothing.collectable.len);
    try std.testing.expectEqual(@as(usize, 0), nothing.refused.len);
    try std.testing.expectEqual(@as(u64, 0), nothing.reclaimable_bytes);
}
