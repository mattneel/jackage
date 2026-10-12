//! Keeping each platform's compiler cache in its own tree (M12, SPACE-006).
//!
//! A compiler cache is not portable. Object files, debug paths, and the recorded
//! flags are bound to the platform that produced them, so a Windows cache staged
//! under a Linux build either fails outright or, worse, is accepted for a
//! translation unit that was never compiled that way. And a cache written *into the
//! source tree* is copied by every subsequent snapshot, so a wrong cache becomes a
//! permanent part of the project.
//!
//! Synchronization therefore routes by platform: every entry names the platform that
//! produced it, it is placed under that platform's own root, a request to place it
//! anywhere else is refused with a reason, and no cache may resolve inside a source
//! root at all. Nothing is copied here - the plan is the description, and the
//! refusals are the safety property.
const std = @import("std");

pub const Error = error{
    InvalidEntry,
    OutOfMemory,
};

pub const Platform = enum { windows, linux, macos };

pub const Entry = struct {
    path: []const u8,
    platform: Platform,
    byte_length: u64,
};

pub const Refusal = struct {
    path: []const u8,
    reason: RefusalReason,
};

pub const RefusalReason = enum {
    /// The entry claims a platform root belonging to a different platform.
    foreign_platform_root,
    /// The entry would materialize inside a source tree.
    inside_source_tree,
    /// The entry names a root this synchronization does not own.
    unmanaged_root,
};

pub const Layout = struct {
    /// The cache root per platform, all outside every source tree.
    windows_root: []const u8,
    linux_root: []const u8,
    macos_root: []const u8,
    /// Source trees that no cache may be written into.
    source_roots: []const []const u8,

    pub fn rootFor(self: Layout, platform: Platform) []const u8 {
        return switch (platform) {
            .windows => self.windows_root,
            .linux => self.linux_root,
            .macos => self.macos_root,
        };
    }
};

pub const Placement = struct {
    path: []const u8,
    platform: Platform,
};

pub const Plan = struct {
    placements: []Placement,
    refused: []Refusal,
    bytes_per_platform: [3]u64,

    pub fn deinit(self: Plan, gpa: std.mem.Allocator) void {
        for (self.placements) |placement| gpa.free(placement.path);
        gpa.free(self.placements);
        for (self.refused) |refusal| gpa.free(refusal.path);
        gpa.free(self.refused);
    }

    pub fn refusalFor(self: Plan, path: []const u8) ?RefusalReason {
        for (self.refused) |refusal| {
            if (std.mem.eql(u8, refusal.path, path)) return refusal.reason;
        }
        return null;
    }

    pub fn bytesFor(self: Plan, platform: Platform) u64 {
        return self.bytes_per_platform[@intFromEnum(platform)];
    }
};

const MAX_PATH = 4096;

fn normalize(buffer: []u8, path: []const u8) Error![]u8 {
    if (path.len == 0 or path.len > MAX_PATH) return error.InvalidEntry;
    var parts: [128][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count == 0) return error.InvalidEntry;
            count -= 1;
            continue;
        }
        if (count == parts.len) return error.InvalidEntry;
        parts[count] = part;
        count += 1;
    }
    if (count == 0) return error.InvalidEntry;
    var len: usize = 0;
    for (parts[0..count], 0..) |part, index| {
        if (index > 0) {
            buffer[len] = '/';
            len += 1;
        }
        if (len + part.len > MAX_PATH) return error.InvalidEntry;
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

fn platformOf(root: []const u8, layout: Layout) ?Platform {
    const candidates = [_]struct { platform: Platform, root: []const u8 }{
        .{ .platform = .windows, .root = layout.windows_root },
        .{ .platform = .linux, .root = layout.linux_root },
        .{ .platform = .macos, .root = layout.macos_root },
    };
    for (candidates) |candidate| {
        var buffer: [MAX_PATH]u8 = undefined;
        const normalized = normalize(&buffer, candidate.root) catch continue;
        if (contains(normalized, root)) return candidate.platform;
    }
    return null;
}

/// Routes each entry to its own platform's root, refusing foreign roots and
/// anything that would land inside a source tree.
pub fn synchronize(
    gpa: std.mem.Allocator,
    layout: Layout,
    entries: []const Entry,
) Error!Plan {
    var placements: std.ArrayList(Placement) = .empty;
    errdefer {
        for (placements.items) |placement| gpa.free(placement.path);
        placements.deinit(gpa);
    }
    var refused: std.ArrayList(Refusal) = .empty;
    errdefer {
        for (refused.items) |refusal| gpa.free(refusal.path);
        refused.deinit(gpa);
    }
    var bytes: [3]u64 = .{ 0, 0, 0 };

    for (entries) |entry| {
        var buffer: [MAX_PATH]u8 = undefined;
        const normalized = try normalize(&buffer, entry.path);

        // No cache may be written into a source tree: it would be copied by every
        // subsequent snapshot and become a permanent part of the project.
        var in_source = false;
        for (layout.source_roots) |source| {
            var source_buffer: [MAX_PATH]u8 = undefined;
            const normalized_source = try normalize(&source_buffer, source);
            if (contains(normalized_source, normalized)) {
                try refused.append(gpa, .{
                    .path = try gpa.dupe(u8, entry.path),
                    .reason = .inside_source_tree,
                });
                in_source = true;
                break;
            }
        }
        if (in_source) continue;

        // The entry must land under the root belonging to its own platform.
        const owning = platformOf(normalized, layout) orelse {
            try refused.append(gpa, .{
                .path = try gpa.dupe(u8, entry.path),
                .reason = .unmanaged_root,
            });
            continue;
        };
        if (owning != entry.platform) {
            try refused.append(gpa, .{
                .path = try gpa.dupe(u8, entry.path),
                .reason = .foreign_platform_root,
            });
            continue;
        }

        try placements.append(gpa, .{
            .path = try gpa.dupe(u8, entry.path),
            .platform = entry.platform,
        });
        bytes[@intFromEnum(entry.platform)] += entry.byte_length;
    }

    return .{
        .placements = try placements.toOwnedSlice(gpa),
        .refused = try refused.toOwnedSlice(gpa),
        .bytes_per_platform = bytes,
    };
}

test "m12/SPACE-006 separate platform caches: no cache reaches another platform or the source" {
    std.debug.print("JCKG_EVIDENCE SPACE-006\n", .{});
    const gpa = std.testing.allocator;

    const layout = Layout{
        .windows_root = "C:/Users/me/jackage/caches/windows",
        .linux_root = "/home/me/.jackage/caches/linux",
        .macos_root = "/Users/me/.jackage/caches/macos",
        .source_roots = &.{ "C:/src/myproject" },
    };

    const entries = [_]Entry{
        // Each platform's own cache: routed to its own root.
        .{ .path = "C:/Users/me/jackage/caches/windows/zig/abc", .platform = .windows, .byte_length = 4096 },
        .{ .path = "/home/me/.jackage/caches/linux/zig/abc", .platform = .linux, .byte_length = 8192 },
        // A Windows cache claiming the Linux root: the cross-platform mistake the
        // case is about, refused rather than placed.
        .{ .path = "/home/me/.jackage/caches/linux/zig/from-windows", .platform = .windows, .byte_length = 1024 },
        // A cache requested inside the source tree.
        .{ .path = "C:/src/myproject/.cache/zig/abc", .platform = .windows, .byte_length = 512 },
        // A disguised path reaching the source tree through a root that is managed.
        .{ .path = "C:/Users/me/jackage/caches/windows/../../../../../src/myproject/obj", .platform = .windows, .byte_length = 256 },
        // A root this synchronization does not own.
        .{ .path = "C:/temp/cache/zig/abc", .platform = .windows, .byte_length = 128 },
    };

    const plan = try synchronize(gpa, layout, &entries);
    defer plan.deinit(gpa);

    // Two placements, one per platform, and no path is in the other's root.
    try std.testing.expectEqual(@as(usize, 2), plan.placements.len);
    for (plan.placements) |placement| {
        const other = if (placement.platform == .windows) layout.linux_root else layout.windows_root;
        try std.testing.expect(!std.mem.startsWith(u8, placement.path, other));
        try std.testing.expect(!std.mem.startsWith(u8, placement.path, "C:/src/myproject"));
    }

    // Each platform's bytes are counted separately, so a shared cache size is never
    // reported as if it belonged to one platform.
    try std.testing.expectEqual(@as(u64, 4096), plan.bytesFor(.windows));
    try std.testing.expectEqual(@as(u64, 8192), plan.bytesFor(.linux));
    try std.testing.expectEqual(@as(u64, 0), plan.bytesFor(.macos));

    // Every refusal names its rule.
    try std.testing.expectEqual(@as(usize, 4), plan.refused.len);
    try std.testing.expectEqual(
        RefusalReason.foreign_platform_root,
        plan.refusalFor("/home/me/.jackage/caches/linux/zig/from-windows").?,
    );
    try std.testing.expectEqual(
        RefusalReason.inside_source_tree,
        plan.refusalFor("C:/src/myproject/.cache/zig/abc").?,
    );
    try std.testing.expectEqual(
        RefusalReason.inside_source_tree,
        plan.refusalFor("C:/Users/me/jackage/caches/windows/../../../../../src/myproject/obj").?,
    );
    try std.testing.expectEqual(
        RefusalReason.unmanaged_root,
        plan.refusalFor("C:/temp/cache/zig/abc").?,
    );

    // With no entries there is nothing to place and nothing to refuse.
    const empty = try synchronize(gpa, layout, &.{});
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty.placements.len);
    try std.testing.expectEqual(@as(u64, 0), empty.bytesFor(.windows));
}
