//! Bounding caches against a policy ceiling (M12, SPACE-005).
//!
//! A cache is disposable by definition, so the interesting part is not "delete
//! something" - it is deciding what may *not* be deleted, and being honest when the
//! budget cannot be met.
//!
//! - A **pinned** cache is held by policy: evicting it would invalidate a guarantee
//!   someone asked for.
//! - A cache with an **active lease** is in use by running work: evicting it would
//!   remove bytes an action is currently reading.
//! - The rest are eligible, oldest first, until the ceiling is met.
//!
//! When the eligible caches are exhausted and the total is still over the ceiling,
//! the report says so with the *shortfall in bytes* rather than pretending the
//! budget was satisfied. An unsatisfied budget that stays explicit is a fact
//! somebody can act on; one that is quietly rounded away is a lie.
const std = @import("std");

pub const Error = error{
    InvalidPolicy,
    DuplicateCache,
    OutOfMemory,
};

pub const Cache = struct {
    name: []const u8,
    bytes: u64,
    /// Larger is more recent. Callers set it from whatever clock they use.
    last_used: u64,
    pinned: bool = false,
    active_leases: usize = 0,

    pub fn evictable(self: Cache) bool {
        return !self.pinned and self.active_leases == 0;
    }
};

pub const Report = struct {
    /// The caches that were removed, in the order they were chosen.
    evicted: [][]const u8,
    /// Bytes reclaimed by those removals.
    reclaimed_bytes: u64,
    /// Bytes still over the ceiling after evicting everything eligible. Zero means
    /// the budget was met.
    shortfall_bytes: u64,
    /// Caches kept because policy pins them or work holds a lease.
    retained: [][]const u8,

    pub fn deinit(self: Report, gpa: std.mem.Allocator) void {
        for (self.evicted) |name| gpa.free(name);
        gpa.free(self.evicted);
        for (self.retained) |name| gpa.free(name);
        gpa.free(self.retained);
    }

    pub fn satisfied(self: Report) bool {
        return self.shortfall_bytes == 0;
    }
};

/// Chooses what to evict so the remaining caches fit `ceiling_bytes`.
///
/// The returned plan is a description, not an action: applying it is the caller's
/// job, which keeps a policy decision separable from a destructive one.
pub fn plan(gpa: std.mem.Allocator, caches: []const Cache, ceiling_bytes: u64) Error!Report {
    if (ceiling_bytes > 9007199254740991) return error.InvalidPolicy;

    for (caches, 0..) |cache, index| {
        for (caches[index + 1 ..]) |other| {
            if (std.mem.eql(u8, cache.name, other.name)) return error.DuplicateCache;
        }
    }

    var total: u64 = 0;
    for (caches) |cache| total += cache.bytes;

    var evicted: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (evicted.items) |name| gpa.free(name);
        evicted.deinit(gpa);
    }
    var retained: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (retained.items) |name| gpa.free(name);
        retained.deinit(gpa);
    }

    // Retained caches are collected before any choice is made, so the report
    // answers "what could not be touched" independently of what was evicted.
    for (caches) |cache| {
        if (!cache.evictable()) try retained.append(gpa, try gpa.dupe(u8, cache.name));
    }

    var reclaimed: u64 = 0;
    while (total > ceiling_bytes) {
        // The oldest eligible cache, chosen fresh each round: as caches are removed
        // the choice stays correct without a sorted copy of the inputs.
        var chosen: ?usize = null;
        for (caches, 0..) |cache, index| {
            if (!cache.evictable()) continue;
            var already = false;
            for (evicted.items) |name| {
                if (std.mem.eql(u8, name, cache.name)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            if (chosen == null or cache.last_used < caches[chosen.?].last_used) chosen = index;
        }
        const index = chosen orelse break;
        const cache = caches[index];
        try evicted.append(gpa, try gpa.dupe(u8, cache.name));
        total -= cache.bytes;
        reclaimed += cache.bytes;
    }

    return .{
        .evicted = try evicted.toOwnedSlice(gpa),
        .reclaimed_bytes = reclaimed,
        .shortfall_bytes = if (total > ceiling_bytes) total - ceiling_bytes else 0,
        .retained = try retained.toOwnedSlice(gpa),
    };
}

test "m12/SPACE-005 bound caches: eligible caches shrink and unsatisfied budgets stay explicit" {
    std.debug.print("JCKG_EVIDENCE SPACE-005\n", .{});
    const gpa = std.testing.allocator;

    // Three project caches over a 100-byte ceiling. One is pinned by policy, one is
    // leased by running work, and one is merely old.
    const caches = [_]Cache{
        .{ .name = "oldest-eligible", .bytes = 60, .last_used = 1 },
        .{ .name = "pinned", .bytes = 40, .last_used = 2, .pinned = true },
        .{ .name = "leased", .bytes = 40, .last_used = 3, .active_leases = 1 },
        .{ .name = "recent-eligible", .bytes = 60, .last_used = 4 },
    };
    const report = try plan(gpa, &caches, 100);
    defer report.deinit(gpa);

    // 200 bytes total, ceiling 100: the eligible caches are evicted oldest first
    // until the budget is met, and the pinned and leased caches are untouched.
    try std.testing.expectEqual(@as(usize, 2), report.evicted.len);
    try std.testing.expectEqualStrings("oldest-eligible", report.evicted[0]);
    try std.testing.expectEqualStrings("recent-eligible", report.evicted[1]);
    try std.testing.expectEqual(@as(u64, 120), report.reclaimed_bytes);
    try std.testing.expect(report.satisfied());
    try std.testing.expectEqual(@as(usize, 2), report.retained.len);
    try std.testing.expectEqualStrings("pinned", report.retained[0]);
    try std.testing.expectEqualStrings("leased", report.retained[1]);
    for (report.evicted) |name| {
        try std.testing.expect(!std.mem.eql(u8, name, "pinned"));
        try std.testing.expect(!std.mem.eql(u8, name, "leased"));
    }

    // A ceiling that cannot be met by evicting everything eligible still reports a
    // number, because "unsatisfied" is a fact rather than a failure to report.
    const beyond_reach = try plan(gpa, &caches, 10);
    defer beyond_reach.deinit(gpa);
    try std.testing.expect(!beyond_reach.satisfied());
    try std.testing.expectEqual(@as(u64, 70), beyond_reach.shortfall_bytes);
    try std.testing.expectEqual(@as(u64, 120), beyond_reach.reclaimed_bytes);

    // Nothing eligible at all: no eviction, and the whole overage is the shortfall.
    const only_retained = [_]Cache{
        .{ .name = "pinned", .bytes = 80, .last_used = 1, .pinned = true },
        .{ .name = "leased", .bytes = 80, .last_used = 2, .active_leases = 2 },
    };
    const blocked = try plan(gpa, &only_retained, 100);
    defer blocked.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), blocked.evicted.len);
    try std.testing.expectEqual(@as(u64, 60), blocked.shortfall_bytes);

    // A ceiling already satisfied evicts nothing, which is the ordinary case.
    const satisfied = try plan(gpa, &caches, 1000);
    defer satisfied.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), satisfied.evicted.len);
    try std.testing.expect(satisfied.satisfied());

    // A duplicated cache is refused: two entries with one name make the accounting
    // meaningless.
    const duplicated = [_]Cache{
        .{ .name = "cache", .bytes = 10, .last_used = 1 },
        .{ .name = "cache", .bytes = 20, .last_used = 2 },
    };
    try std.testing.expectError(error.DuplicateCache, plan(gpa, &duplicated, 5));
}
