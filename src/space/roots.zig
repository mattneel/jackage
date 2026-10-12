//! Attributing every retained object to a root (M12, SPACE-002).
//!
//! Collection decides what to keep by reachability, and reachability is only
//! meaningful when it can be *explained*: an object that survives because "something
//! references it" is an object nobody can audit. This module computes the retained
//! set and, for every object in it, the retainers that hold it - profiles, pins,
//! runtime references, and leases - so a retained object always has an attributable
//! root, and an object with none is by construction not retained.
//!
//! An object held by two roots is attributed to both. Reporting only the first would
//! be true and useless: removing one root would then look safe when the other still
//! needs the object.
//!
//! Names are compared as given, and a duplicated retainer name is refused, because
//! two entries with one name make the attribution ambiguous exactly where it needs
//! to be exact.
const std = @import("std");
const digest = @import("../core/digest.zig");

pub const Error = error{
    DuplicateRetainer,
    InvalidRetainer,
    OutOfMemory,
};

pub const Kind = enum { profile, pin, runtime_reference, lease };

pub const Retainer = struct {
    kind: Kind,
    /// How the retainer is named in the report: a profile name, a pin label, and so
    /// on. Empty names are refused - an unattributable root is not a root.
    name: []const u8,
    /// The objects this retainer holds, as canonical digest text.
    objects: []const []const u8,
};

/// One retained object and the retainers that hold it.
pub const Attribution = struct {
    object: []const u8,
    /// Every retainer holding it, in the order the retainers were given. At least
    /// one, by construction.
    retainers: []const []const u8,

    pub fn deinit(self: Attribution, gpa: std.mem.Allocator) void {
        for (self.retainers) |name| gpa.free(name);
        gpa.free(self.retainers);
    }
};

pub const Reachability = struct {
    retained: []Attribution,

    pub fn deinit(self: Reachability, gpa: std.mem.Allocator) void {
        for (self.retained) |attribution| gpa.free(attribution.object);
        for (self.retained) |attribution| attribution.deinit(gpa);
        gpa.free(self.retained);
    }

    /// The retainers holding one object, or null when nothing holds it - which is
    /// exactly the case collection may act on.
    pub fn attributionFor(self: Reachability, object: []const u8) ?Attribution {
        for (self.retained) |attribution| {
            if (std.mem.eql(u8, attribution.object, object)) return attribution;
        }
        return null;
    }
};

fn describe(gpa: std.mem.Allocator, retainer: Retainer) Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}:{s}", .{ @tagName(retainer.kind), retainer.name });
}

/// Computes the retained set, with every object's retainers named.
pub fn compute(gpa: std.mem.Allocator, retainers: []const Retainer) Error!Reachability {
    for (retainers, 0..) |retainer, index| {
        if (retainer.name.len == 0) return error.InvalidRetainer;
        for (retainers[index + 1 ..]) |other| {
            if (retainer.kind == other.kind and std.mem.eql(u8, retainer.name, other.name)) {
                return error.DuplicateRetainer;
            }
        }
        for (retainer.objects) |object| {
            if (object.len == 0) return error.InvalidRetainer;
            // A retainer that names something which is not a digest is a retainer
            // whose reference cannot be checked against the store.
            _ = digest.Digest.parse(object) catch return error.InvalidRetainer;
        }
    }

    var retained: std.ArrayList(Attribution) = .empty;
    errdefer {
        for (retained.items) |attribution| gpa.free(attribution.object);
        for (retained.items) |attribution| attribution.deinit(gpa);
        retained.deinit(gpa);
    }

    for (retainers) |retainer| {
        const label = try describe(gpa, retainer);
        defer gpa.free(label);
        for (retainer.objects) |object| {
            // First sighting: the object joins the retained set with this retainer.
            var found: ?usize = null;
            for (retained.items, 0..) |attribution, index| {
                if (std.mem.eql(u8, attribution.object, object)) {
                    found = index;
                    break;
                }
            }
            if (found) |index| {
                const existing = retained.items[index].retainers;
                var already = false;
                for (existing) |name| {
                    if (std.mem.eql(u8, name, label)) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
                // The existing entries are copied as pointers and remain owned by
                // the grown array: freeing them here would leave the array holding
                // dangling strings that `deinit` frees again.
                const grown = try gpa.alloc([]const u8, existing.len + 1);
                @memcpy(grown[0..existing.len], existing);
                grown[existing.len] = try gpa.dupe(u8, label);
                gpa.free(existing);
                retained.items[index].retainers = grown;
                continue;
            }
            const names = try gpa.alloc([]const u8, 1);
            names[0] = try gpa.dupe(u8, label);
            try retained.append(gpa, .{ .object = try gpa.dupe(u8, object), .retainers = names });
        }
    }
    return .{ .retained = try retained.toOwnedSlice(gpa) };
}

test "m12/SPACE-002 trace roots: every retained object is attributable and nothing else is retained" {
    std.debug.print("JCKG_EVIDENCE SPACE-002\n", .{});
    const gpa = std.testing.allocator;

    const shared = "sha256:1111111111111111111111111111111111111111111111111111111111111111";
    const profile_only = "sha256:2222222222222222222222222222222222222222222222222222222222222222";
    const pinned = "sha256:3333333333333333333333333333333333333333333333333333333333333333";
    const leased = "sha256:4444444444444444444444444444444444444444444444444444444444444444";
    const unreferenced = "sha256:5555555555555555555555555555555555555555555555555555555555555555";

    // Four kinds of root, one of them holding an object that another also holds.
    const retainers = [_]Retainer{
        .{ .kind = .profile, .name = "default", .objects = &.{ shared, profile_only } },
        .{ .kind = .pin, .name = "lockfile", .objects = &.{pinned} },
        .{ .kind = .runtime_reference, .name = "service", .objects = &.{shared} },
        .{ .kind = .lease, .name = "running-action", .objects = &.{leased} },
    };

    const reachability = try compute(gpa, &retainers);
    defer reachability.deinit(gpa);

    // Four objects are retained, and the unreferenced one is not: an object with no
    // root is exactly what collection may act on.
    try std.testing.expectEqual(@as(usize, 4), reachability.retained.len);
    try std.testing.expect(reachability.attributionFor(unreferenced) == null);

    // Every retained object names its root, by kind and name.
    const shared_attribution = reachability.attributionFor(shared).?;
    try std.testing.expectEqual(@as(usize, 2), shared_attribution.retainers.len);
    try std.testing.expectEqualStrings("profile:default", shared_attribution.retainers[0]);
    try std.testing.expectEqualStrings("runtime_reference:service", shared_attribution.retainers[1]);

    try std.testing.expectEqualStrings("profile:default", reachability.attributionFor(profile_only).?.retainers[0]);
    try std.testing.expectEqualStrings("pin:lockfile", reachability.attributionFor(pinned).?.retainers[0]);
    try std.testing.expectEqualStrings("lease:running-action", reachability.attributionFor(leased).?.retainers[0]);

    // A retainer with no name is refused: an unattributable root is not a root.
    const anonymous = [_]Retainer{.{ .kind = .profile, .name = "", .objects = &.{shared} }};
    try std.testing.expectError(error.InvalidRetainer, compute(gpa, &anonymous));

    // An object that is not a digest is refused: the reference could not be checked
    // against the store, so attributing it would be attributing nothing.
    const bogus = [_]Retainer{.{ .kind = .pin, .name = "lockfile", .objects = &.{"not-a-digest"} }};
    try std.testing.expectError(error.InvalidRetainer, compute(gpa, &bogus));

    // Two retainers of the same kind with one name are refused, because two entries
    // with one label make the attribution ambiguous.
    const duplicated = [_]Retainer{
        .{ .kind = .profile, .name = "default", .objects = &.{shared} },
        .{ .kind = .profile, .name = "default", .objects = &.{pinned} },
    };
    try std.testing.expectError(error.DuplicateRetainer, compute(gpa, &duplicated));

    // The same name in two different kinds is fine: a profile and a lease may share
    // a label without being the same root.
    const cross_kind = [_]Retainer{
        .{ .kind = .profile, .name = "default", .objects = &.{shared} },
        .{ .kind = .lease, .name = "default", .objects = &.{pinned} },
    };
    const crossed = try compute(gpa, &cross_kind);
    defer crossed.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), crossed.retained.len);

    // With no retainers at all, nothing is retained and nothing is attributed.
    const empty = try compute(gpa, &.{});
    defer empty.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), empty.retained.len);
}
