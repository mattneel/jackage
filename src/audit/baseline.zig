//! Baseline command bookkeeping (case AUD-005).
//!
//! The audit records the real exit code of each baseline command and keeps a
//! pre-existing failure distinguishable from a failure introduced later. A
//! baseline that was green must not be reported as if something had failed,
//! and a new failure must not hide behind an old one.
const std = @import("std");

pub const Run = struct {
    /// Stable command identity, for example "build" or "build test".
    name: []const u8,
    /// Exact command line that was executed.
    command: []const u8,
    exit_code: i32,
    log_path: []const u8,

    pub fn failed(self: Run) bool {
        return self.exit_code != 0;
    }
};

pub const Outcome = enum {
    /// Failed before the change and still fails with the same code.
    preserved_failure,
    /// Failed before the change, now fails with a different code.
    changed_failure,
    /// Passed before the change and fails now: introduced by this work.
    new_failure,
    /// Failed before the change and passes now.
    fixed,
    /// Passed before and after.
    still_passing,
    /// Did not run before, passes now.
    new_pass,
};

pub const Entry = struct {
    name: []const u8,
    baseline: ?Run,
    current: ?Run,
    outcome: Outcome,
};

pub const Diff = struct {
    entries: []Entry,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Diff) void {
        self.gpa.free(self.entries);
        self.* = undefined;
    }

    pub fn countOf(self: Diff, outcome: Outcome) usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            if (entry.outcome == outcome) total += 1;
        }
        return total;
    }

    pub fn countFailures(self: Diff) usize {
        return self.countOf(.preserved_failure) + self.countOf(.changed_failure) + self.countOf(.new_failure);
    }
};

pub const Failure = error{NewFailure};

fn findRun(runs: []const Run, name: []const u8) ?Run {
    for (runs) |run| {
        if (std.mem.eql(u8, run.name, name)) return run;
    }
    return null;
}

/// Compares a recorded baseline with the current observation set.
pub fn classify(gpa: std.mem.Allocator, baseline_runs: []const Run, current_runs: []const Run) !Diff {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);

    for (baseline_runs) |baseline_run| {
        const current_run = findRun(current_runs, baseline_run.name);
        try entries.append(gpa, .{
            .name = baseline_run.name,
            .baseline = baseline_run,
            .current = current_run,
            .outcome = outcomeFor(baseline_run, current_run),
        });
    }
    for (current_runs) |current_run| {
        if (findRun(baseline_runs, current_run.name) != null) continue;
        try entries.append(gpa, .{
            .name = current_run.name,
            .baseline = null,
            .current = current_run,
            .outcome = if (current_run.failed()) .new_failure else .new_pass,
        });
    }

    return .{ .entries = try entries.toOwnedSlice(gpa), .gpa = gpa };
}

fn outcomeFor(baseline_run: Run, current_run: ?Run) Outcome {
    const current = current_run orelse return .preserved_failure;
    if (!baseline_run.failed()) {
        return if (current.failed()) .new_failure else .still_passing;
    }
    if (!current.failed()) return .fixed;
    return if (current.exit_code == baseline_run.exit_code) .preserved_failure else .changed_failure;
}

/// Fails when the current observation contains a failure the baseline did not
/// contain: new failures are never absorbed into the baseline.
pub fn assertNoNewFailures(diff: Diff) Failure!void {
    for (diff.entries) |entry| {
        switch (entry.outcome) {
            .new_failure => return error.NewFailure,
            else => {},
        }
    }
}

const baseline_fixture = [_]Run{
    .{ .name = "build", .command = "zig build", .exit_code = 3, .log_path = "baseline/build.log" },
    .{ .name = "version", .command = "zig version", .exit_code = 0, .log_path = "baseline/version.log" },
};

test "m00/AUD-005 record baseline failures" {
    std.debug.print("JCKG_EVIDENCE AUD-005\n", .{});
    const gpa = std.testing.allocator;

    // Baseline fixture with one genuine pre-existing failure (exit 3) and one
    // passing command. The failure must be preserved with its real exit code.
    const current_with_new_failure = [_]Run{
        .{ .name = "build", .command = "zig build", .exit_code = 3, .log_path = "current/build.log" },
        .{ .name = "version", .command = "zig version", .exit_code = 0, .log_path = "current/version.log" },
        .{ .name = "test", .command = "zig build test", .exit_code = 1, .log_path = "current/test.log" },
    };

    var diff = try classify(gpa, &baseline_fixture, &current_with_new_failure);
    defer diff.deinit();

    try std.testing.expectEqual(@as(usize, 3), diff.entries.len);
    try std.testing.expectEqual(@as(usize, 1), diff.countOf(.preserved_failure));
    try std.testing.expectEqual(@as(usize, 1), diff.countOf(.new_failure));
    try std.testing.expectEqual(@as(usize, 1), diff.countOf(.still_passing));
    // The pre-existing failure stays visible next to the new one.
    try std.testing.expectEqual(@as(usize, 2), diff.countFailures());

    const build_entry = blk: {
        for (diff.entries) |entry| {
            if (std.mem.eql(u8, entry.name, "build")) break :blk entry;
        }
        return error.MissingEntry;
    };
    try std.testing.expectEqual(Outcome.preserved_failure, build_entry.outcome);
    const build_run = build_entry.baseline orelse return error.MissingBaselineRun;
    try std.testing.expectEqual(@as(i32, 3), build_run.exit_code);

    // A pre-existing failure must never be reported as introduced by this work.
    var failures: std.ArrayList([]const u8) = .empty;
    defer failures.deinit(gpa);
    for (diff.entries) |entry| {
        if (entry.outcome != .new_failure) continue;
        try failures.append(gpa, entry.name);
    }
    try std.testing.expectEqual(@as(usize, 1), failures.items.len);
    try std.testing.expectEqualStrings("test", failures.items[0]);
    try std.testing.expectError(error.NewFailure, assertNoNewFailures(diff));

    // Negative-or-recovery: when the baseline failure is repaired, the change
    // is reported as fixed and no new failure exists.
    const current_repaired = [_]Run{
        .{ .name = "build", .command = "zig build", .exit_code = 0, .log_path = "current/build.log" },
        .{ .name = "version", .command = "zig version", .exit_code = 0, .log_path = "current/version.log" },
    };
    var repaired = try classify(gpa, &baseline_fixture, &current_repaired);
    defer repaired.deinit();
    try std.testing.expectEqual(@as(usize, 1), repaired.countOf(.fixed));
    try std.testing.expectEqual(@as(usize, 0), repaired.countFailures());
    try assertNoNewFailures(repaired);

    // A command that only exists after the change cannot claim a baseline.
    const current_extra = [_]Run{
        .{ .name = "package", .command = "jckg package", .exit_code = 0, .log_path = "current/package.log" },
    };
    var extra = try classify(gpa, &baseline_fixture, &current_extra);
    defer extra.deinit();
    try std.testing.expectEqual(@as(usize, 1), extra.countOf(.new_pass));
    // Commands that were not observed now keep their baseline state visible.
    try std.testing.expectEqual(@as(usize, 2), extra.countOf(.preserved_failure));
    try std.testing.expectEqual(@as(usize, 0), extra.countOf(.new_failure));

    // A different exit code is a changed failure, not a silent pass.
    const current_changed = [_]Run{
        .{ .name = "build", .command = "zig build", .exit_code = 2, .log_path = "current/build.log" },
    };
    var changed = try classify(gpa, &baseline_fixture, &current_changed);
    defer changed.deinit();
    try std.testing.expectEqual(@as(usize, 1), changed.countOf(.changed_failure));
    try std.testing.expectEqual(@as(usize, 0), changed.countOf(.fixed));
}
