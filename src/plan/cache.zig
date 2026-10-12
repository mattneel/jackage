//! Action cache: action identity versus artifact identity (cases PLAN-008,
//! PLAN-011).
//!
//! An action identity names the requested computation; an artifact identity
//! names the bytes that came out. Two different artifacts under one action
//! identity mean nondeterminism or a compromised execution path, so the cache
//! keeps both and reports the discrepancy instead of overwriting the earlier
//! result. A hit must also satisfy the requesting policy: a cached development
//! result never answers a release request.
const std = @import("std");
const planner = @import("planner.zig");

pub const OutputRecord = struct {
    name: []const u8,
    digest: []const u8,
};

pub const Entry = struct {
    /// Action identity text (`sha256:...`).
    action_digest: []const u8,
    /// Artifact identity text (`sha256:...`).
    artifact_digest: []const u8,
    policy: planner.CachePolicy,
    backend_identity: []const u8,
    /// Whether two independent executions produced equal bytes.
    reproducible: bool = false,
    outputs: []const OutputRecord = &.{},

    /// Why this entry cannot answer `requirements`, or null when it can.
    pub fn incompatibility(self: Entry, requirements: Requirements) ?[]const u8 {
        return incompatibilityText(self, requirements);
    }
};

pub const Requirements = struct {
    policy: planner.CachePolicy,
    require_reproducible: bool = false,
    require_backend: ?[]const u8 = null,
};

pub const Discrepancy = struct {
    action_digest: []const u8,
    first_artifact: []const u8,
    second_artifact: []const u8,
    message: []const u8,
};

pub const RecordOutcome = union(enum) {
    /// First result for this action identity.
    inserted,
    /// An equivalent claim already exists: same action, artifact, policy,
    /// backend identity and reproducibility. Nothing new to keep.
    converged,
    /// Same action and same artifact, but different provenance (policy, backend
    /// or reproducibility). The claim is kept as an additional entry so a
    /// release request can be satisfied by the release claim instead of being
    /// refused because a development claim happened to arrive first.
    provenance_added,
    /// Same action, different artifact: both are kept and the difference is
    /// reported.
    discrepancy: Discrepancy,
};

pub const Incompatibility = struct {
    reason: []const u8,
};

pub const Lookup = union(enum) {
    hit: usize,
    miss,
    incompatible: Incompatibility,
};

pub const Error = error{
    UncacheableAction,
    DuplicateOutput,
};

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// Discrepancy explanations, owned by the cache: a returned `Discrepancy`
    /// borrows from them and stays valid for the cache's lifetime.
    messages: std.ArrayList([]const u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |entry| freeEntry(self.gpa, entry);
        self.entries.deinit(self.gpa);
        for (self.messages.items) |message| self.gpa.free(message);
        self.messages.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn count(self: Cache) usize {
        return self.entries.items.len;
    }

    pub fn entryAt(self: Cache, index: usize) Entry {
        return self.entries.items[index];
    }

    /// Records a result. A non-cacheable action is refused outright, and a
    /// second, different artifact for the same action identity is kept as a
    /// visible discrepancy.
    pub fn record(self: *Cache, entry: Entry) (Error || std.mem.Allocator.Error)!RecordOutcome {
        if (entry.policy == .noncacheable) return error.UncacheableAction;
        for (entry.outputs, 0..) |output, index| {
            for (entry.outputs[index + 1 ..]) |other| {
                if (std.mem.eql(u8, output.name, other.name)) return error.DuplicateOutput;
            }
        }

        // Scan all claims for this action identity: an *equivalent* claim (same
        // action, artifact, policy, backend, reproducibility) converges, a
        // different artifact is a discrepancy, and the same artifact with
        // different provenance is a new claim that must stay visible.
        var equivalent_seen = false;
        var same_artifact_other_provenance = false;
        var differing_artifact: ?Entry = null;
        for (self.entries.items) |existing| {
            if (!std.mem.eql(u8, existing.action_digest, entry.action_digest)) continue;
            if (std.mem.eql(u8, existing.artifact_digest, entry.artifact_digest)) {
                if (equivalentProvenance(existing, entry)) {
                    equivalent_seen = true;
                    break;
                }
                same_artifact_other_provenance = true;
                continue;
            }
            if (differing_artifact == null) differing_artifact = existing;
        }
        if (equivalent_seen) return .converged;

        // A claim about the *same bytes* is a provenance addition, not a new
        // discrepancy: the discrepancy was reported when the differing artifact
        // itself arrived. Only a claim about different bytes reports one.
        if (same_artifact_other_provenance) {
            try self.entries.append(self.gpa, try cloneEntry(self.gpa, entry));
            return .provenance_added;
        }

        if (differing_artifact) |existing| {
            const stored = try cloneEntry(self.gpa, entry);
            errdefer freeEntry(self.gpa, stored);
            try self.entries.append(self.gpa, stored);
            const message = try self.gpa.print(
                "action {s} produced {s} and {s}: the earlier result is kept and the difference is reported",
                .{ entry.action_digest, existing.artifact_digest, entry.artifact_digest },
            );
            errdefer self.gpa.free(message);
            try self.messages.append(self.gpa, message);
            return .{ .discrepancy = .{
                .action_digest = existing.action_digest,
                .first_artifact = existing.artifact_digest,
                .second_artifact = entry.artifact_digest,
                .message = message,
            } };
        }

        const saw_same_action = for (self.entries.items) |existing| {
            if (std.mem.eql(u8, existing.action_digest, entry.action_digest)) break true;
        } else false;

        try self.entries.append(self.gpa, try cloneEntry(self.gpa, entry));
        return if (saw_same_action) .provenance_added else .inserted;
    }

    /// Looks up a usable result for the requested provenance.
    pub fn lookup(self: Cache, action_digest: []const u8, requirements: Requirements) Lookup {
        var saw_entry = false;
        var first_incompatibility: ?[]const u8 = null;
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.action_digest, action_digest)) continue;
            saw_entry = true;
            if (entry.incompatibility(requirements)) |reason| {
                if (first_incompatibility == null) first_incompatibility = reason;
                continue;
            }
            return .{ .hit = index };
        }
        if (saw_entry) {
            return .{ .incompatible = .{ .reason = first_incompatibility orelse "cached entry does not satisfy the requested provenance" } };
        }
        return .miss;
    }

    /// The artifact recorded first for this action identity. It is what a
    /// discrepancy reports as the earlier result, and it never changes.
    pub fn artifactFor(self: Cache, action_digest: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.action_digest, action_digest)) return entry.artifact_digest;
        }
        return null;
    }
};

fn equivalentProvenance(a: Entry, b: Entry) bool {
    return a.policy == b.policy and
        a.reproducible == b.reproducible and
        std.mem.eql(u8, a.backend_identity, b.backend_identity);
}

fn freeEntry(gpa: std.mem.Allocator, entry: Entry) void {
    gpa.free(entry.action_digest);
    gpa.free(entry.artifact_digest);
    gpa.free(entry.backend_identity);
    for (entry.outputs) |output| {
        gpa.free(output.name);
        gpa.free(output.digest);
    }
    gpa.free(entry.outputs);
}

fn cloneEntry(gpa: std.mem.Allocator, entry: Entry) std.mem.Allocator.Error!Entry {
    const outputs = try gpa.alloc(OutputRecord, entry.outputs.len);
    errdefer gpa.free(outputs);
    for (entry.outputs, 0..) |output, index| {
        outputs[index] = .{
            .name = try gpa.dupe(u8, output.name),
            .digest = try gpa.dupe(u8, output.digest),
        };
    }
    return .{
        .action_digest = try gpa.dupe(u8, entry.action_digest),
        .artifact_digest = try gpa.dupe(u8, entry.artifact_digest),
        .policy = entry.policy,
        .backend_identity = try gpa.dupe(u8, entry.backend_identity),
        .reproducible = entry.reproducible,
        .outputs = outputs,
    };
}

fn incompatibilityText(entry: Entry, requirements: Requirements) ?[]const u8 {
    if (entry.policy == .noncacheable) return "the cached entry is not cacheable";
    if (requirements.policy == .release and entry.policy != .release) {
        return "the cached result has development provenance, but release provenance was required";
    }
    if (requirements.policy == .development and entry.policy == .noncacheable) {
        return "the cached entry is not cacheable";
    }
    if (requirements.require_reproducible and !entry.reproducible) {
        return "the cached result was not verified by an independent reproduction";
    }
    if (requirements.require_backend) |backend| {
        if (!std.mem.eql(u8, entry.backend_identity, backend)) {
            return "the cached result came from a different backend";
        }
    }
    return null;
}

pub const fixture_action_digest = "sha256:5555555555555555555555555555555555555555555555555555555555555555";

test "m05/PLAN-008 separate action and artifact identity" {
    std.debug.print("JCKG_EVIDENCE PLAN-008\n", .{});
    const gpa = std.testing.allocator;
    var cache = Cache.init(gpa);
    defer cache.deinit();

    const outputs = [_]OutputRecord{.{ .name = "zig-out", .digest = "sha256:6666666666666666666666666666666666666666666666666666666666666666" }};
    const first = Entry{
        .action_digest = fixture_action_digest,
        .artifact_digest = "sha256:7777777777777777777777777777777777777777777777777777777777777777",
        .policy = .release,
        .backend_identity = "native-process",
        .reproducible = true,
        .outputs = &outputs,
    };
    try std.testing.expectEqual(RecordOutcome.inserted, try cache.record(first));

    // The same action and artifact converge: no duplicate entry.
    try std.testing.expectEqual(RecordOutcome.converged, try cache.record(first));
    try std.testing.expectEqual(@as(usize, 1), cache.count());

    // A different artifact under the same action identity is kept and reported.
    const second = Entry{
        .action_digest = fixture_action_digest,
        .artifact_digest = "sha256:8888888888888888888888888888888888888888888888888888888888888888",
        .policy = .release,
        .backend_identity = "native-process",
        .reproducible = true,
        .outputs = &outputs,
    };
    const outcome = try cache.record(second);
    try std.testing.expect(outcome == .discrepancy);
    try std.testing.expectEqualStrings(first.artifact_digest, outcome.discrepancy.first_artifact);
    try std.testing.expectEqualStrings(second.artifact_digest, outcome.discrepancy.second_artifact);
    try std.testing.expect(std.mem.indexOf(u8, outcome.discrepancy.message, "kept") != null);

    // Both results remain visible; the earlier one is not replaced.
    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expectEqualStrings(first.artifact_digest, cache.artifactFor(fixture_action_digest).?);
    try std.testing.expectEqualStrings(second.artifact_digest, cache.entryAt(1).artifact_digest);

    // The same bytes with a *different* provenance is not a silent convergence:
    // the claim is kept, so a later request with stronger requirements can find
    // it instead of being refused because the weaker claim arrived first.
    const development_claim = Entry{
        .action_digest = fixture_action_digest,
        .artifact_digest = first.artifact_digest,
        .policy = .development,
        .backend_identity = "native-process",
        .reproducible = false,
        .outputs = &outputs,
    };
    try std.testing.expectEqual(RecordOutcome.provenance_added, try cache.record(development_claim));
    // Repeating that exact claim now converges: an equivalent entry exists.
    try std.testing.expectEqual(RecordOutcome.converged, try cache.record(development_claim));
    try std.testing.expectEqual(@as(usize, 3), cache.count());
    // The earlier artifact identity is still what a discrepancy reports.
    try std.testing.expectEqualStrings(first.artifact_digest, cache.artifactFor(fixture_action_digest).?);

    // Negative-or-recovery: a non-cacheable action is refused, and duplicate
    // output names are rejected before anything is recorded.
    var rejected = Entry{
        .action_digest = "sha256:9999999999999999999999999999999999999999999999999999999999999999",
        .artifact_digest = "sha256:9999999999999999999999999999999999999999999999999999999999999998",
        .policy = .noncacheable,
        .backend_identity = "native-process",
    };
    try std.testing.expectError(error.UncacheableAction, cache.record(rejected));
    try std.testing.expectEqual(@as(usize, 3), cache.count());

    const duplicated = [_]OutputRecord{
        .{ .name = "out", .digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111" },
        .{ .name = "out", .digest = "sha256:2222222222222222222222222222222222222222222222222222222222222222" },
    };
    rejected.outputs = &duplicated;
    rejected.policy = .release;
    try std.testing.expectError(error.DuplicateOutput, cache.record(rejected));
}

test "m05/PLAN-011 preserve cache policy" {
    std.debug.print("JCKG_EVIDENCE PLAN-011\n", .{});
    const gpa = std.testing.allocator;
    var cache = Cache.init(gpa);
    defer cache.deinit();

    const development = Entry{
        .action_digest = fixture_action_digest,
        .artifact_digest = "sha256:7777777777777777777777777777777777777777777777777777777777777777",
        .policy = .development,
        .backend_identity = "native-process",
        .reproducible = false,
    };
    try std.testing.expectEqual(RecordOutcome.inserted, try cache.record(development));

    // A development result does not answer a release request.
    const release_requirements = Requirements{ .policy = .release, .require_reproducible = true };
    const refused = cache.lookup(fixture_action_digest, release_requirements);
    try std.testing.expect(refused == .incompatible);
    try std.testing.expect(std.mem.indexOf(u8, refused.incompatible.reason, "release provenance") != null);

    // It does answer a development request that asks for nothing more.
    const development_lookup = cache.lookup(fixture_action_digest, .{ .policy = .development });
    try std.testing.expect(development_lookup == .hit);

    // Requiring an independent reproduction or a specific backend also refuses.
    const reproduction_requirements = Requirements{ .policy = .development, .require_reproducible = true };
    try std.testing.expect(cache.lookup(fixture_action_digest, reproduction_requirements) == .incompatible);
    const backend_requirements = Requirements{ .policy = .development, .require_backend = "strict-linux" };
    const backend_refused = cache.lookup(fixture_action_digest, backend_requirements);
    try std.testing.expect(backend_refused == .incompatible);
    try std.testing.expect(std.mem.indexOf(u8, backend_refused.incompatible.reason, "backend") != null);

    // Qualified execution: the release run produces different bytes under the
    // same action identity, so it is recorded as a visible discrepancy and now
    // answers the release request. The development entry stays visible.
    const release = Entry{
        .action_digest = fixture_action_digest,
        .artifact_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .policy = .release,
        .backend_identity = "strict-linux",
        .reproducible = true,
    };
    const release_outcome = try cache.record(release);
    try std.testing.expect(release_outcome == .discrepancy);
    try std.testing.expectEqualStrings(development.artifact_digest, release_outcome.discrepancy.first_artifact);
    try std.testing.expectEqualStrings(release.artifact_digest, release_outcome.discrepancy.second_artifact);
    const qualified = cache.lookup(fixture_action_digest, release_requirements);
    try std.testing.expect(qualified == .hit);
    try std.testing.expectEqual(@as(usize, 1), qualified.hit);
    try std.testing.expectEqual(@as(usize, 2), cache.count());

    // A release claim for the *same bytes* as the development entry must not be
    // discarded: it is kept as a separate claim and immediately satisfies the
    // release request. Converging on bytes alone would hide it.
    const release_same_bytes = Entry{
        .action_digest = fixture_action_digest,
        .artifact_digest = development.artifact_digest,
        .policy = .release,
        .backend_identity = "strict-linux",
        .reproducible = true,
    };
    try std.testing.expectEqual(RecordOutcome.provenance_added, try cache.record(release_same_bytes));

    // The release claim for the *same bytes* is visible: at least one entry
    // satisfies the release requirements with the development artifact's exact
    // bytes, which is precisely what byte-only convergence used to hide.
    var found_upgrade = false;
    for (0..cache.count()) |index| {
        const candidate = cache.entryAt(index);
        if (candidate.incompatibility(release_requirements) != null) continue;
        if (!std.mem.eql(u8, candidate.artifact_digest, development.artifact_digest)) continue;
        try std.testing.expectEqual(planner.CachePolicy.release, candidate.policy);
        try std.testing.expect(candidate.reproducible);
        found_upgrade = true;
    }
    try std.testing.expect(found_upgrade);
    // The development request still finds a development-provenance entry, and
    // the cache still reports hits for both requirement profiles.
    try std.testing.expect(cache.lookup(fixture_action_digest, .{ .policy = .development }) == .hit);
    try std.testing.expect(cache.lookup(fixture_action_digest, release_requirements) == .hit);
    try std.testing.expectEqual(@as(usize, 3), cache.count());

    // Negative-or-recovery: an unknown action identity is a miss, not a
    // fabricated hit.
    try std.testing.expect(cache.lookup("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", release_requirements) == .miss);

    // A non-cacheable action never enters the cache at all.
    const noncacheable = Entry{
        .action_digest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .artifact_digest = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        .policy = .noncacheable,
        .backend_identity = "native-process",
    };
    try std.testing.expectError(error.UncacheableAction, cache.record(noncacheable));
    try std.testing.expect(cache.lookup(noncacheable.action_digest, release_requirements) == .miss);
}
