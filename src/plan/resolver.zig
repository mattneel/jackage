//! Deterministic dependency resolution (cases PLAN-001, PLAN-002, PLAN-003).
//!
//! Resolution is exhaustive over the declared candidate pool with a fixed
//! order: requirements are processed by key, candidates newest first. The same
//! pool and the same roots therefore always produce the same exact closure, and
//! a failure produces a stable explanation that names the requirement, who
//! asked for it, and which versions were available. A namespace is part of the
//! identity, so a package name alone can never be satisfied by an unrelated
//! repository.
const std = @import("std");
const version = @import("version.zig");

pub const Candidate = struct {
    /// Repository namespace, for example `example.invalid/acme`.
    namespace: []const u8,
    name: []const u8,
    version: version.Version,
    /// Artifact digest text (`sha256:...`).
    artifact_digest: []const u8,
    dependencies: []const Dependency = &.{},
    /// Output platform for platform-specific packages.
    output_platform: ?[]const u8 = null,
};

pub const Dependency = struct {
    namespace: []const u8,
    name: []const u8,
    requirement: version.Requirement,
};

pub const Selection = struct {
    namespace: []const u8,
    name: []const u8,
    version: version.Version,
    artifact_digest: []const u8,
};

pub const Origin = struct {
    namespace: []const u8,
    name: []const u8,
    version: version.Version,
};

pub const Conflict = struct {
    /// `namespace/name` that could not be satisfied.
    dependency_namespace: []const u8,
    dependency_name: []const u8,
    /// Rendered requirement that failed.
    requirement: []const u8,
    /// `namespace/name@version` of the requirer, or "root".
    requirer: []const u8,
    /// Rendered versions that exist for that package.
    available: []const []const u8,
    /// Human explanation with a stable shape.
    message: []const u8,
    gpa: std.mem.Allocator,
    /// Set by the resolver for the requirer line it allocated.
    owned_requirement_line: ?[]const u8 = null,

    pub fn deinit(self: *Conflict) void {
        self.gpa.free(self.requirement);
        for (self.available) |entry| self.gpa.free(entry);
        self.gpa.free(self.available);
        self.gpa.free(self.requirer);
        self.gpa.free(self.message);
        if (self.owned_requirement_line) |line| self.gpa.free(line);
        self.* = undefined;
    }
};

pub const Resolution = struct {
    selections: []Selection,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Resolution) void {
        self.gpa.free(self.selections);
        self.* = undefined;
    }

    pub fn find(self: Resolution, namespace: []const u8, name: []const u8) ?Selection {
        for (self.selections) |selection| {
            if (std.mem.eql(u8, selection.namespace, namespace) and std.mem.eql(u8, selection.name, name)) {
                return selection;
            }
        }
        return null;
    }
};

pub const Outcome = union(enum) {
    resolved: Resolution,
    conflict: Conflict,
};

const Requirement = struct {
    namespace: []const u8,
    name: []const u8,
    requirement: version.Requirement,
    origin: ?Origin,
};

/// Upper bound on the backtracking depth of one resolution attempt.
const max_search_depth = 1024;

const Search = struct {
    gpa: std.mem.Allocator,
    pool: []const Candidate,
    selections: std.ArrayList(Selection) = .empty,
    /// Deepest failure seen, kept for the explanation.
    failure: ?Failure = null,

    const Failure = struct {
        requirement: Requirement,
        depth: usize,
        /// Number of candidates that exist for the package at all.
        available_versions: []const Candidate,
    };

    fn selected(self: *Search, namespace: []const u8, name: []const u8) ?Selection {
        for (self.selections.items) |selection| {
            if (std.mem.eql(u8, selection.namespace, namespace) and std.mem.eql(u8, selection.name, name)) return selection;
        }
        return null;
    }

    fn satisfiesAll(self: *Search, requirements: []const Requirement, candidate: Candidate) bool {
        _ = self;
        for (requirements) |entry| {
            if (!std.mem.eql(u8, entry.namespace, candidate.namespace)) continue;
            if (!std.mem.eql(u8, entry.name, candidate.name)) continue;
            if (!entry.requirement.satisfiedBy(candidate.version)) return false;
        }
        return true;
    }

    fn step(self: *Search, requirements: *std.ArrayList(Requirement), depth: usize) std.mem.Allocator.Error!bool {
        // The search is a depth-first backtracking walk; a malformed candidate
        // pool must not be able to exhaust the stack, so the walk has a budget
        // and reports a conflict when it is exceeded.
        if (depth > max_search_depth) return false;
        // A requirement can be introduced after its package was selected (a
        // later candidate brings its own constraint). The whole set is checked
        // before going on, so an incompatible selection is detected instead of
        // being reported as a successful resolution.
        for (requirements.items) |entry| {
            const selection = self.selected(entry.namespace, entry.name) orelse continue;
            if (!entry.requirement.satisfiedBy(selection.version)) {
                if (self.failure == null or depth >= self.failure.?.depth) {
                    self.failure = .{ .requirement = entry, .depth = depth, .available_versions = self.pool };
                }
                return false;
            }
        }

        // Pick the first unselected key in byte order.
        var pending: ?[]const u8 = null;
        var pending_namespace: []const u8 = "";
        var pending_name: []const u8 = "";
        for (requirements.items) |entry| {
            if (self.selected(entry.namespace, entry.name) != null) continue;
            if (pending == null or std.mem.lessThan(u8, entry.name, pending_name)) {
                pending = entry.name;
                pending_namespace = entry.namespace;
                pending_name = entry.name;
            }
        }
        if (pending == null) return true;

        // Collect candidates in deterministic order: newest first, then digest.
        var chosen: ?usize = null;
        var order: std.ArrayList(usize) = .empty;
        defer order.deinit(self.gpa);
        for (self.pool, 0..) |candidate, index| {
            if (!std.mem.eql(u8, candidate.namespace, pending_namespace)) continue;
            if (!std.mem.eql(u8, candidate.name, pending_name)) continue;
            if (!self.satisfiesAll(requirements.items, candidate)) continue;
            try order.append(self.gpa, index);
        }
        std.mem.sortUnstable(usize, order.items, self.pool, lessCandidateIndex);

        for (order.items) |index| {
            const candidate = self.pool[index];
            const saved_selection_length = self.selections.items.len;
            const saved_requirement_length = requirements.items.len;
            try self.selections.append(self.gpa, .{
                .namespace = candidate.namespace,
                .name = candidate.name,
                .version = candidate.version,
                .artifact_digest = candidate.artifact_digest,
            });
            for (candidate.dependencies) |dependency| {
                try requirements.append(self.gpa, .{
                    .namespace = dependency.namespace,
                    .name = dependency.name,
                    .requirement = dependency.requirement,
                    .origin = .{ .namespace = candidate.namespace, .name = candidate.name, .version = candidate.version },
                });
            }
            if (try self.step(requirements, depth + 1)) {
                chosen = index;
                break;
            }
            self.selections.shrinkRetainingCapacity(saved_selection_length);
            requirements.shrinkRetainingCapacity(saved_requirement_length);
        }

        if (chosen != null) return true;

        // Record the deepest failure: this is the requirement that could not be met.
        if (self.failure == null or depth >= self.failure.?.depth) {
            var origin: ?Origin = null;
            var required: Requirement = undefined;
            for (requirements.items) |entry| {
                if (std.mem.eql(u8, entry.namespace, pending_namespace) and std.mem.eql(u8, entry.name, pending_name)) {
                    if (origin == null) {
                        origin = entry.origin;
                        required = entry;
                    }
                }
            }
            if (origin != null or true) {
                self.failure = .{ .requirement = required, .depth = depth, .available_versions = self.pool };
            }
        }
        return false;
    }
};

fn lessCandidateIndex(pool: []const Candidate, a: usize, b: usize) bool {
    const left = pool[a];
    const right = pool[b];
    switch (version.Version.compare(left.version, right.version)) {
        .gt => return true,
        .lt => return false,
        .eq => return std.mem.lessThan(u8, left.artifact_digest, right.artifact_digest),
    }
}

pub fn resolve(
    gpa: std.mem.Allocator,
    pool: []const Candidate,
    roots: []const Dependency,
) std.mem.Allocator.Error!Outcome {
    var search = Search{ .gpa = gpa, .pool = pool };
    defer search.selections.deinit(gpa);

    var requirements: std.ArrayList(Requirement) = .empty;
    defer requirements.deinit(gpa);
    for (roots) |root| {
        try requirements.append(gpa, .{
            .namespace = root.namespace,
            .name = root.name,
            .requirement = root.requirement,
            .origin = null,
        });
    }

    const ok = try search.step(&requirements, 0);
    if (ok) {
        const selections = try gpa.dupe(Selection, search.selections.items);
        std.mem.sortUnstable(Selection, selections, {}, lessSelection);
        return .{ .resolved = .{ .selections = selections, .gpa = gpa } };
    }

    const failure = search.failure orelse FailureFallback;
    return .{ .conflict = try buildConflict(gpa, pool, failure) };
}

const FailureFallback = Search.Failure{
    .requirement = .{ .namespace = "", .name = "", .requirement = .any, .origin = null },
    .depth = 0,
    .available_versions = &.{},
};

fn lessSelection(_: void, a: Selection, b: Selection) bool {
    if (!std.mem.eql(u8, a.namespace, b.namespace)) return std.mem.lessThan(u8, a.namespace, b.namespace);
    return std.mem.lessThan(u8, a.name, b.name);
}

fn buildConflict(gpa: std.mem.Allocator, pool: []const Candidate, failure: Search.Failure) std.mem.Allocator.Error!Conflict {
    var requirement_buffer: [64]u8 = undefined;
    var version_buffer: [64]u8 = undefined;

    const requirement_text = try gpa.dupe(u8, failure.requirement.requirement.text(&requirement_buffer));

    const requirer_text = if (failure.requirement.origin) |origin|
        try gpa.print("{s}/{s}@{s}", .{ origin.namespace, origin.name, origin.version.text(&version_buffer) })
    else
        try gpa.dupe(u8, "root");

    // Every version that exists for the requested package.
    var available: std.ArrayList([]const u8) = .empty;
    for (pool) |candidate| {
        if (!std.mem.eql(u8, candidate.namespace, failure.requirement.namespace)) continue;
        if (!std.mem.eql(u8, candidate.name, failure.requirement.name)) continue;
        var buffer: [64]u8 = undefined;
        try available.append(gpa, try gpa.dupe(u8, candidate.version.text(&buffer)));
    }
    std.mem.sortUnstable([]const u8, available.items, {}, lessString);

    const message = try gpa.print(
        "no version of {s}/{s} satisfies {s} required by {s}; available versions: {s}{s}",
        .{
            failure.requirement.namespace,
            failure.requirement.name,
            requirement_text,
            requirer_text,
            if (available.items.len == 0) "none" else available.items[0],
            if (available.items.len <= 1) "" else " (and newer/older candidates)",
        },
    );

    return .{
        .dependency_namespace = failure.requirement.namespace,
        .dependency_name = failure.requirement.name,
        .requirement = requirement_text,
        .requirer = requirer_text,
        .available = try available.toOwnedSlice(gpa),
        .message = message,
        .gpa = gpa,
        .owned_requirement_line = null,
    };
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------------------
// Fixture graph used by the resolution cases.
// ---------------------------------------------------------------------------

pub const fixture_namespace = "example.invalid/acme";
pub const other_namespace = "example.invalid/other";

pub const fixture_pool = [_]Candidate{
    .{
        .namespace = fixture_namespace,
        .name = "app",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .artifact_digest = "sha256:aa00000000000000000000000000000000000000000000000000000000000001",
        .dependencies = &.{
            .{ .namespace = fixture_namespace, .name = "lib", .requirement = .{ .caret = .{ .major = 1, .minor = 0, .patch = 0 } } },
        },
    },
    .{
        .namespace = fixture_namespace,
        .name = "app",
        .version = .{ .major = 1, .minor = 1, .patch = 0 },
        .artifact_digest = "sha256:aa00000000000000000000000000000000000000000000000000000000000002",
        .dependencies = &.{
            .{ .namespace = fixture_namespace, .name = "lib", .requirement = .{ .caret = .{ .major = 1, .minor = 0, .patch = 0 } } },
        },
    },
    .{
        .namespace = fixture_namespace,
        .name = "lib",
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .artifact_digest = "sha256:bb00000000000000000000000000000000000000000000000000000000000001",
    },
    .{
        .namespace = fixture_namespace,
        .name = "lib",
        .version = .{ .major = 1, .minor = 1, .patch = 0 },
        .artifact_digest = "sha256:bb00000000000000000000000000000000000000000000000000000000000002",
    },
    .{
        .namespace = fixture_namespace,
        .name = "lib",
        .version = .{ .major = 2, .minor = 0, .patch = 0 },
        .artifact_digest = "sha256:bb00000000000000000000000000000000000000000000000000000000000003",
    },
    .{
        // Same name, unrelated repository: it must never satisfy acme/lib.
        .namespace = other_namespace,
        .name = "lib",
        .version = .{ .major = 1, .minor = 1, .patch = 0 },
        .artifact_digest = "sha256:cc00000000000000000000000000000000000000000000000000000000000001",
    },
};

test "m05/PLAN-001 resolve exact closure" {
    std.debug.print("JCKG_EVIDENCE PLAN-001\n", .{});
    const gpa = std.testing.allocator;
    const roots = [_]Dependency{
        .{ .namespace = fixture_namespace, .name = "app", .requirement = .any },
    };

    var first = try resolve(gpa, &fixture_pool, &roots);
    defer switch (first) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*conflict| conflict.deinit(),
    };
    try std.testing.expect(first == .resolved);
    const first_resolution = first.resolved;
    try std.testing.expectEqual(@as(usize, 2), first_resolution.selections.len);
    const app = first_resolution.find(fixture_namespace, "app") orelse return error.MissingSelection;
    const lib = first_resolution.find(fixture_namespace, "lib") orelse return error.MissingSelection;
    try std.testing.expectEqual(@as(u32, 1), app.version.major);
    try std.testing.expectEqual(@as(u32, 1), app.version.minor);
    try std.testing.expectEqual(@as(u32, 1), lib.version.minor);

    // The closure is canonical: byte-identical selections on a second run.
    var second = try resolve(gpa, &fixture_pool, &roots);
    defer switch (second) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*conflict| conflict.deinit(),
    };
    try std.testing.expect(second == .resolved);
    try std.testing.expectEqual(first_resolution.selections.len, second.resolved.selections.len);
    for (first_resolution.selections, second.resolved.selections) |left, right| {
        try std.testing.expectEqualStrings(left.namespace, right.namespace);
        try std.testing.expectEqualStrings(left.name, right.name);
        try std.testing.expectEqualStrings(left.artifact_digest, right.artifact_digest);
        try std.testing.expect(version.Version.compare(left.version, right.version) == .eq);
    }

    // Negative-or-recovery: an exact requirement selects that version only,
    // even though newer versions exist.
    const exact_roots = [_]Dependency{
        .{ .namespace = fixture_namespace, .name = "lib", .requirement = .{ .exact = .{ .major = 1, .minor = 0, .patch = 0 } } },
    };
    var exact = try resolve(gpa, &fixture_pool, &exact_roots);
    defer switch (exact) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*conflict| conflict.deinit(),
    };
    try std.testing.expect(exact == .resolved);
    try std.testing.expectEqual(@as(usize, 1), exact.resolved.selections.len);
    try std.testing.expectEqual(@as(u32, 0), exact.resolved.selections[0].version.minor);

    // An unsatisfiable root reports a conflict instead of guessing.
    const impossible_roots = [_]Dependency{
        .{ .namespace = fixture_namespace, .name = "lib", .requirement = .{ .caret = .{ .major = 3, .minor = 0, .patch = 0 } } },
    };
    var impossible = try resolve(gpa, &fixture_pool, &impossible_roots);
    defer switch (impossible) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*conflict| conflict.deinit(),
    };
    try std.testing.expect(impossible == .conflict);
}

test "m05/PLAN-002 explain conflicts" {
    std.debug.print("JCKG_EVIDENCE PLAN-002\n", .{});
    const gpa = std.testing.allocator;

    // Two roots demand incompatible major versions of the same package.
    const conflicting_pool = fixture_pool ++ [_]Candidate{
        .{
            .namespace = fixture_namespace,
            .name = "strict",
            .version = .{ .major = 1, .minor = 0, .patch = 0 },
            .artifact_digest = "sha256:dd00000000000000000000000000000000000000000000000000000000000001",
            .dependencies = &.{
                .{ .namespace = fixture_namespace, .name = "lib", .requirement = .{ .caret = .{ .major = 2, .minor = 0, .patch = 0 } } },
            },
        },
    };
    const roots = [_]Dependency{
        .{ .namespace = fixture_namespace, .name = "app", .requirement = .any },
        .{ .namespace = fixture_namespace, .name = "strict", .requirement = .any },
    };

    var first = try resolve(gpa, &conflicting_pool, &roots);
    defer switch (first) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*raised| raised.deinit(),
    };
    try std.testing.expect(first == .conflict);
    const conflict = first.conflict;

    // The explanation names the package, the requirement, who asked for it and
    // what exists - all three are needed to act on it.
    try std.testing.expectEqualStrings("lib", conflict.dependency_name);
    try std.testing.expectEqualStrings(fixture_namespace, conflict.dependency_namespace);
    try std.testing.expect(conflict.requirement.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, conflict.requirer, "app") != null or
        std.mem.indexOf(u8, conflict.requirer, "strict") != null);
    try std.testing.expect(conflict.available.len >= 2);
    try std.testing.expect(std.mem.indexOf(u8, conflict.message, "lib") != null);
    try std.testing.expect(std.mem.indexOf(u8, conflict.message, "satisfies") != null);

    // The explanation is stable across runs.
    var second = try resolve(gpa, &conflicting_pool, &roots);
    defer switch (second) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*raised| raised.deinit(),
    };
    try std.testing.expect(second == .conflict);
    try std.testing.expectEqualStrings(conflict.message, second.conflict.message);
    try std.testing.expectEqualStrings(conflict.requirement, second.conflict.requirement);

    // Negative-or-recovery: a graph that is compatible resolves, so the
    // conflict is not reported for a satisfiable request.
    const fine_roots = [_]Dependency{
        .{ .namespace = fixture_namespace, .name = "app", .requirement = .any },
        .{ .namespace = fixture_namespace, .name = "lib", .requirement = .{ .caret = .{ .major = 1, .minor = 0, .patch = 0 } } },
    };
    var fine = try resolve(gpa, &conflicting_pool, &fine_roots);
    defer switch (fine) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*raised| raised.deinit(),
    };
    try std.testing.expect(fine == .resolved);
}

test "m05/PLAN-003 preserve namespaces" {
    std.debug.print("JCKG_EVIDENCE PLAN-003\n", .{});
    const gpa = std.testing.allocator;

    // Only the unrelated repository publishes lib 1.0.0: the acme requirement
    // must fail even though a package named lib exists elsewhere.
    const pool = [_]Candidate{
        .{
            .namespace = other_namespace,
            .name = "lib",
            .version = .{ .major = 1, .minor = 0, .patch = 0 },
            .artifact_digest = "sha256:cc00000000000000000000000000000000000000000000000000000000000002",
        },
    };
    const roots = [_]Dependency{
        .{ .namespace = fixture_namespace, .name = "lib", .requirement = .any },
    };
    var outcome = try resolve(gpa, &pool, &roots);
    defer switch (outcome) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*conflict| conflict.deinit(),
    };
    try std.testing.expect(outcome == .conflict);
    try std.testing.expectEqualStrings(fixture_namespace, outcome.conflict.dependency_namespace);

    // Both namespaces can be selected side by side, and each keeps its own
    // artifact identity even at the same version.
    const both_roots = [_]Dependency{
        .{ .namespace = fixture_namespace, .name = "lib", .requirement = .{ .exact = .{ .major = 1, .minor = 1, .patch = 0 } } },
        .{ .namespace = other_namespace, .name = "lib", .requirement = .{ .exact = .{ .major = 1, .minor = 1, .patch = 0 } } },
    };
    var both = try resolve(gpa, &fixture_pool, &both_roots);
    defer switch (both) {
        .resolved => |*resolution| resolution.deinit(),
        .conflict => |*conflict| conflict.deinit(),
    };
    try std.testing.expect(both == .resolved);
    try std.testing.expectEqual(@as(usize, 2), both.resolved.selections.len);
    const acme_lib = both.resolved.find(fixture_namespace, "lib") orelse return error.MissingSelection;
    const other_lib = both.resolved.find(other_namespace, "lib") orelse return error.MissingSelection;
    try std.testing.expect(!std.mem.eql(u8, acme_lib.artifact_digest, other_lib.artifact_digest));

    // Negative-or-recovery: the same name in a different namespace never
    // satisfies a requirement, even at the same version.
    try std.testing.expect(version.Version.compare(acme_lib.version, other_lib.version) == .eq);
}
