//! Comparing independent self-hosted build stages (M09, SELF-004).
//!
//! Reproducibility is a *comparison*, and a comparison that only ever says "looks
//! equal" is worthless. This module compares two stages' declared artifacts and
//! answers with the artifacts that differ, by name:
//!
//! - equal payloads pass;
//! - unequal payloads produce a reproducibility failure that names every artifact
//!   whose digest differs;
//! - a different *set* of artifacts is a failure too - one stage producing an
//!   output the other did not is not "equal", and reporting it as such would hide
//!   exactly the drift the comparison exists to catch.
//!
//! Artifact names are compared as given: two stages that name the same artifact
//! differently have not produced comparable outputs, and saying so is more useful
//! than a fuzzy match.
const std = @import("std");

pub const Error = error{
    /// The two stages do not describe the same set of artifacts.
    ArtifactSetMismatch,
    OutOfMemory,
    WriteFailed,
};

pub const Artifact = struct {
    name: []const u8,
    /// Lowercase hex SHA-256 of the artifact's payload.
    sha256: []const u8,
};

pub const Difference = struct {
    name: []const u8,
    /// The digest the first stage recorded, or null when it did not produce it.
    first: ?[]const u8,
    /// The digest the second stage recorded, or null when it did not produce it.
    second: ?[]const u8,
};

pub const Comparison = struct {
    compared: usize,
    differences: []Difference,

    pub fn equal(self: Comparison) bool {
        return self.differences.len == 0;
    }

    pub fn deinit(self: Comparison, gpa: std.mem.Allocator) void {
        for (self.differences) |difference| gpa.free(difference.name);
        gpa.free(self.differences);
    }
};

fn find(artifacts: []const Artifact, name: []const u8) ?Artifact {
    for (artifacts) |artifact| {
        if (std.mem.eql(u8, artifact.name, name)) return artifact;
    }
    return null;
}

/// Compares two stages artifact by artifact.
///
/// The returned comparison is empty when the stages agree. Every artifact that
/// exists in one stage but not the other is a difference, not a skip: a stage that
/// silently stopped producing an output is the failure mode this is for.
pub fn compare(
    gpa: std.mem.Allocator,
    first: []const Artifact,
    second: []const Artifact,
) Error!Comparison {
    var differences: std.ArrayList(Difference) = .empty;
    errdefer {
        for (differences.items) |difference| gpa.free(difference.name);
        differences.deinit(gpa);
    }

    var compared: usize = 0;
    for (first) |artifact| {
        compared += 1;
        const other = find(second, artifact.name);
        if (other == null) {
            try differences.append(gpa, .{
                .name = try gpa.dupe(u8, artifact.name),
                .first = artifact.sha256,
                .second = null,
            });
            continue;
        }
        if (!std.mem.eql(u8, artifact.sha256, other.?.sha256)) {
            try differences.append(gpa, .{
                .name = try gpa.dupe(u8, artifact.name),
                .first = artifact.sha256,
                .second = other.?.sha256,
            });
        }
    }
    for (second) |artifact| {
        if (find(first, artifact.name) == null) {
            try differences.append(gpa, .{
                .name = try gpa.dupe(u8, artifact.name),
                .first = null,
                .second = artifact.sha256,
            });
        }
    }
    return .{ .compared = compared, .differences = try differences.toOwnedSlice(gpa) };
}

/// Renders a comparison for a report: one line per differing artifact, naming both
/// digests so the reader can see *how* they differ, not merely that they do.
pub fn describe(gpa: std.mem.Allocator, comparison: Comparison) Error![]u8 {
    var text: std.Io.Writer.Allocating = .init(gpa);
    errdefer text.deinit();
    const writer = &text.writer;
    for (comparison.differences) |difference| {
        try writer.print("{s}: first={s} second={s}\n", .{
            difference.name,
            difference.first orelse "(absent)",
            difference.second orelse "(absent)",
        });
    }
    return text.toOwnedSlice();
}

test "m09/SELF-004 compare stages: equal payloads pass, unequal payloads fail" {
    std.debug.print("JCKG_EVIDENCE SELF-004\n", .{});
    const gpa = std.testing.allocator;

    const digest_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const digest_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    // Equivalent recipes and toolchains produce equal payloads: the comparison is
    // empty and the stages pass.
    const b1 = [_]Artifact{
        .{ .name = "jckg", .sha256 = digest_a },
        .{ .name = "jckg-worker", .sha256 = digest_b },
    };
    const b2 = [_]Artifact{
        .{ .name = "jckg", .sha256 = digest_a },
        .{ .name = "jckg-worker", .sha256 = digest_b },
    };
    const equal = try compare(gpa, &b1, &b2);
    defer equal.deinit(gpa);
    try std.testing.expect(equal.equal());
    try std.testing.expectEqual(@as(usize, 2), equal.compared);

    // An unequal payload is a reproducibility failure that names the artifact and
    // both digests, so the reader can see how they differ.
    const drifted = [_]Artifact{
        .{ .name = "jckg", .sha256 = digest_b },
        .{ .name = "jckg-worker", .sha256 = digest_b },
    };
    const unequal = try compare(gpa, &b1, &drifted);
    defer unequal.deinit(gpa);
    try std.testing.expect(!unequal.equal());
    try std.testing.expectEqual(@as(usize, 1), unequal.differences.len);
    try std.testing.expectEqualStrings("jckg", unequal.differences[0].name);
    try std.testing.expectEqualStrings(digest_a, unequal.differences[0].first.?);
    try std.testing.expectEqualStrings(digest_b, unequal.differences[0].second.?);

    const report = try describe(gpa, unequal);
    defer gpa.free(report);
    try std.testing.expect(std.mem.indexOf(u8, report, "jckg:") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, digest_a) != null);

    // A different *set* of artifacts is a failure in both directions: an output one
    // stage stopped producing, and an output the other gained, each get named with
    // an explicit absence rather than being skipped.
    const missing_output = [_]Artifact{
        .{ .name = "jckg", .sha256 = digest_a },
    };
    const missing = try compare(gpa, &b1, &missing_output);
    defer missing.deinit(gpa);
    try std.testing.expect(!missing.equal());
    try std.testing.expectEqual(@as(usize, 1), missing.differences.len);
    try std.testing.expectEqualStrings("jckg-worker", missing.differences[0].name);
    try std.testing.expect(missing.differences[0].first != null);
    try std.testing.expect(missing.differences[0].second == null);

    const gained = try compare(gpa, &missing_output, &b1);
    defer gained.deinit(gpa);
    try std.testing.expect(!gained.equal());
    try std.testing.expectEqualStrings("jckg-worker", gained.differences[0].name);
    try std.testing.expect(gained.differences[0].first == null);
    try std.testing.expect(gained.differences[0].second != null);

    // Two empty stages agree, and the comparison says so rather than failing.
    const none = [_]Artifact{};
    const both_empty = try compare(gpa, &none, &none);
    defer both_empty.deinit(gpa);
    try std.testing.expect(both_empty.equal());
    try std.testing.expectEqual(@as(usize, 0), both_empty.compared);
}
