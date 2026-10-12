//! Applying collection against a lease table that can change underneath it (M12, SPACE-003).
//!
//! Collection has two moments and only one of them is safe to trust: candidates are
//! selected against the leases that exist *then*, and deletion happens later. An
//! action that starts in between holds a lease the selection never saw. Deleting
//! that object removes bytes a running action is reading.
//!
//! The protocol here is therefore two-phase, and the second phase re-checks:
//! selection produces a plan, and applying the plan re-reads the lease table for
//! each candidate, retaining anything that acquired a lease rather than deleting it.
//! The retained objects are reported, so the race is visible in the record instead
//! of being an intermittent failure somebody debugs later.
//!
//! The other direction matters as well: an action that tries to lease an object
//! already marked for deletion is told so and can retry, rather than holding a lease
//! on bytes that are about to disappear.
const std = @import("std");

pub const Error = error{
    ObjectDeleting,
    Leased,
    UnknownObject,
    OutOfMemory,
};

pub const State = enum { live, deleting, deleted };

pub const Store = struct {
    gpa: std.mem.Allocator,
    objects: std.ArrayList(Object) = .empty,

    pub const Object = struct {
        name: []const u8,
        byte_length: u64,
        state: State = .live,
        /// How many leases are held. A nonzero count is what keeps the object.
        leases: usize = 0,
        /// True once a selection has refused to delete it because of a lease, so the
        /// record can say why it survived.
        retained_by_race: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        for (self.objects.items) |object| self.gpa.free(object.name);
        self.objects.deinit(self.gpa);
    }

    pub fn add(self: *Store, name: []const u8, byte_length: u64) !void {
        try self.objects.append(self.gpa, .{
            .name = try self.gpa.dupe(u8, name),
            .byte_length = byte_length,
        });
    }

    pub fn find(self: *Store, name: []const u8) ?*Object {
        for (self.objects.items) |*object| {
            if (std.mem.eql(u8, object.name, name)) return object;
        }
        return null;
    }

    /// Takes a lease so the object survives collection. An object already marked for
    /// deletion is refused, so the caller can retry rather than reading bytes that
    /// are on their way out.
    pub fn lease(self: *Store, name: []const u8) Error!void {
        const object = self.find(name) orelse return error.UnknownObject;
        if (object.state != .live) return error.ObjectDeleting;
        object.leases += 1;
    }

    pub fn release(self: *Store, name: []const u8) Error!void {
        const object = self.find(name) orelse return error.UnknownObject;
        if (object.leases == 0) return error.UnknownObject;
        object.leases -= 1;
    }
};

pub const Selection = struct {
    candidates: []const []const u8,
    skipped_leased: []const []const u8,

    pub fn deinit(self: Selection, gpa: std.mem.Allocator) void {
        for (self.candidates) |name| gpa.free(name);
        gpa.free(self.candidates);
        for (self.skipped_leased) |name| gpa.free(name);
        gpa.free(self.skipped_leased);
    }
};

/// Selects unleased objects as collection candidates. This is the moment the race
/// is *not* yet decided: a lease taken after this point must still be honored.
pub fn select(gpa: std.mem.Allocator, store: *Store) Error!Selection {
    var candidates: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (candidates.items) |name| gpa.free(name);
        candidates.deinit(gpa);
    }
    var skipped: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (skipped.items) |name| gpa.free(name);
        skipped.deinit(gpa);
    }

    for (store.objects.items) |object| {
        if (object.state != .live) continue;
        if (object.leases > 0) {
            try skipped.append(gpa, try gpa.dupe(u8, object.name));
            continue;
        }
        try candidates.append(gpa, try gpa.dupe(u8, object.name));
    }
    return .{
        .candidates = try candidates.toOwnedSlice(gpa),
        .skipped_leased = try skipped.toOwnedSlice(gpa),
    };
}

pub const ApplyReport = struct {
    deleted: []const []const u8,
    /// Candidates that acquired a lease between selection and this moment. These are
    /// the objects the race would have destroyed.
    retained: []const []const u8,
    reclaimed_bytes: u64,

    pub fn deinit(self: ApplyReport, gpa: std.mem.Allocator) void {
        for (self.deleted) |name| gpa.free(name);
        gpa.free(self.deleted);
        for (self.retained) |name| gpa.free(name);
        gpa.free(self.retained);
    }
};

/// Applies a selection, re-reading the lease table for every candidate. A candidate
/// that acquired a lease since selection is retained, not deleted.
pub fn apply(gpa: std.mem.Allocator, store: *Store, selection: Selection) Error!ApplyReport {
    var deleted: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (deleted.items) |name| gpa.free(name);
        deleted.deinit(gpa);
    }
    var retained: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (retained.items) |name| gpa.free(name);
        retained.deinit(gpa);
    }
    var reclaimed: u64 = 0;

    for (selection.candidates) |name| {
        const object = store.find(name) orelse continue;
        if (object.leases > 0 or object.state != .live) {
            // The race happened. The action keeps access, and the object is named in
            // the report so the survival is explained rather than mysterious.
            object.retained_by_race = true;
            try retained.append(gpa, try gpa.dupe(u8, name));
            continue;
        }
        object.state = .deleted;
        reclaimed += object.byte_length;
        try deleted.append(gpa, try gpa.dupe(u8, name));
    }
    return .{
        .deleted = try deleted.toOwnedSlice(gpa),
        .retained = try retained.toOwnedSlice(gpa),
        .reclaimed_bytes = reclaimed,
    };
}

test "m12/SPACE-003 race leases safely: a lease taken after selection keeps its object" {
    std.debug.print("JCKG_EVIDENCE SPACE-003\n", .{});
    const gpa = std.testing.allocator;

    var store = Store.init(gpa);
    defer store.deinit();
    try store.add("cache/one", 1024);
    try store.add("cache/two", 2048);
    try store.add("cache/three", 4096);
    // Already held by a running action: never a candidate at all.
    try store.lease("cache/three");

    // Selection sees two free objects and one held one.
    const selection = try select(gpa, &store);
    defer selection.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), selection.candidates.len);
    try std.testing.expectEqual(@as(usize, 1), selection.skipped_leased.len);
    try std.testing.expectEqualStrings("cache/three", selection.skipped_leased[0]);

    // The race: an action starts and leases an object that selection already chose.
    // This is the moment a naive implementation loses.
    try store.lease("cache/two");

    const report = try apply(gpa, &store, selection);
    defer report.deinit(gpa);

    // The raced object survives, is named as retained, and its bytes are not counted
    // as reclaimed.
    try std.testing.expectEqual(@as(usize, 1), report.deleted.len);
    try std.testing.expectEqualStrings("cache/one", report.deleted[0]);
    try std.testing.expectEqual(@as(usize, 1), report.retained.len);
    try std.testing.expectEqualStrings("cache/two", report.retained[0]);
    try std.testing.expectEqual(@as(u64, 1024), report.reclaimed_bytes);

    // The action that won the race still holds a live object.
    const two = store.find("cache/two").?;
    try std.testing.expectEqual(State.live, two.state);
    try std.testing.expect(two.retained_by_race);
    try std.testing.expectEqual(@as(usize, 1), two.leases);

    // Reading it, then releasing it, then collecting again is the safe sequence.
    try store.release("cache/two");
    const second = try select(gpa, &store);
    defer second.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), second.candidates.len);
    const second_report = try apply(gpa, &store, second);
    defer second_report.deinit(gpa);
    try std.testing.expectEqualStrings("cache/two", second_report.deleted[0]);

    // The other direction: leasing an object already marked for deletion fails, so
    // the action retries before execution instead of reading doomed bytes.
    const three = store.find("cache/three").?;
    three.state = .deleting;
    try std.testing.expectError(error.ObjectDeleting, store.lease("cache/three"));

    // Leasing something that does not exist is distinguished from that.
    try std.testing.expectError(error.UnknownObject, store.lease("cache/absent"));

    // A selection with nothing free collects nothing and still reports cleanly.
    const empty_store = try select(gpa, &store);
    defer empty_store.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty_store.candidates.len);
}
