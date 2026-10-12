//! What is known about an action when its plugin dies (M13, PLUGIN-010).
//!
//! A plugin that terminates during an action leaves a question the core cannot
//! answer from the fact of the crash alone: the work may have completed before the
//! process died, or it may not have started. Both "failed" and "succeeded" are
//! guesses, and a guess about build state is expensive - it either discards work
//! that was done or, far worse, reports success for work that never happened.
//!
//! So the status after a crash is `unknown`, and it stays unknown until evidence
//! reconciles it: the expected artifact present and verified means succeeded, its
//! absence means failed, and no evidence at all means the question is still open.
//! Success is only ever cached after that reconciliation, so a cache lookup for an
//! action whose plugin crashed returns nothing rather than a plausible falsehood.
const std = @import("std");

pub const Error = error{
    UnknownAction,
    OutOfMemory,
};

pub const Status = enum {
    /// The action ran and its result was verified.
    succeeded,
    /// The action ran and did not produce its result, or was cancelled cleanly.
    failed,
    /// The plugin holds the action and has not reported.
    running,
    /// The plugin died and the evidence does not say which way it went.
    unknown,
};

pub const Action = struct {
    name: []const u8,
    status: Status,
    /// Set when a plugin process stopped while this action was its own.
    plugin_died: bool = false,
};

/// A cache of action outcomes. Only reconciled outcomes are written here: this is
/// the structure that would carry a false success forward into later runs.
pub const Cache = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        name: []const u8,
        status: Status,
    };

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Cache) void {
        for (self.entries.items) |entry| self.gpa.free(entry.name);
        self.entries.deinit(self.gpa);
    }

    pub fn record(self: *Cache, name: []const u8, status: Status) !void {
        // An unreconciled status must never be recorded, whatever the caller asks
        // for: the cache is the place a wrong answer would survive into the next run.
        if (status == .unknown or status == .running) return error.UnknownAction;
        try self.entries.append(self.gpa, .{ .name = try self.gpa.dupe(u8, name), .status = status });
    }

    pub fn lookup(self: *Cache, name: []const u8) ?Status {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.status;
        }
        return null;
    }
};

pub const Evidence = struct {
    /// Whether the action's declared output exists and matches its digest.
    artifact_present_and_verified: bool = false,
    /// What the action's own log says. An absent log is not evidence of anything,
    /// which is exactly the crash-before-start case: the artifact is missing because
    /// the work never began, and calling that a failure would be as wrong as calling
    /// it a success.
    log: Log = .absent,

    pub const Log = enum {
        /// No log survived the crash.
        absent,
        /// The log shows the action began.
        started,
        /// The log claims the action completed.
        completed,
    };
};

/// Records that a plugin stopped while it owned this action. The status becomes
/// unknown; nothing is cached, because nothing is known.
pub fn pluginTerminated(action: *Action, cache: *Cache) Error!void {
    _ = cache;
    action.plugin_died = true;
    action.status = .unknown;
}

/// Reconciles an action whose plugin died against the evidence that survived it.
pub fn reconcile(gpa: std.mem.Allocator, action: *Action, evidence: Evidence, cache: *Cache) Error!void {
    _ = gpa;
    if (!action.plugin_died) return;

    if (evidence.artifact_present_and_verified) {
        // The work exists and checks out: that is success, however ungraceful the
        // process exit was.
        action.status = .succeeded;
        try cache.record(action.name, .succeeded);
        return;
    }
    if (evidence.log != .absent) {
        // The log shows the action ran. Without its artifact that is failure - and a
        // log claiming completion while the artifact is missing is a contradiction
        // that resolves against the log, because the artifact is the thing downstream
        // actions consume.
        action.status = .failed;
        try cache.record(action.name, .failed);
        return;
    }
    // No artifact and no log: the action may never have started, so nothing is
    // known. The status stays unknown, exactly as it was, and nothing is cached.
    action.status = .unknown;
}

test "m13/PLUGIN-010 recover plugin crash: unknown until reconciled, and no false success cached" {
    std.debug.print("JCKG_EVIDENCE PLUGIN-010\n", .{});
    const gpa = std.testing.allocator;

    // The plugin dies mid-action.
    var crash_cache = Cache.init(gpa);
    defer crash_cache.deinit();
    var crashed = Action{ .name = "build", .status = .running };
    try pluginTerminated(&crashed, &crash_cache);

    // The status is unknown - not failed, and certainly not succeeded - and the cache
    // holds nothing, so no later run can read a plausible falsehood.
    try std.testing.expectEqual(Status.unknown, crashed.status);
    try std.testing.expect(crashed.status != .succeeded);
    try std.testing.expect(crashed.status != .failed);
    try std.testing.expect(crash_cache.lookup("build") == null);
    // The cache refuses an unreconciled status even if asked directly.
    try std.testing.expectError(error.UnknownAction, crash_cache.record("build", .unknown));
    try std.testing.expectError(error.UnknownAction, crash_cache.record("build", .running));

    // Evidence that the artifact exists and verifies reconciles to success, and only
    // then is success cached.
    var verified_cache = Cache.init(gpa);
    defer verified_cache.deinit();
    var verified = Action{ .name = "build", .status = .running };
    try pluginTerminated(&verified, &verified_cache);
    try reconcile(gpa, &verified, .{ .artifact_present_and_verified = true }, &verified_cache);
    try std.testing.expectEqual(Status.succeeded, verified.status);
    try std.testing.expectEqual(Status.succeeded, verified_cache.lookup("build").?);

    // No artifact: the action failed, and that is what is cached.
    var failed_cache = Cache.init(gpa);
    defer failed_cache.deinit();
    var failed = Action{ .name = "build", .status = .running };
    try pluginTerminated(&failed, &failed_cache);
    try reconcile(gpa, &failed, .{ .log = .started }, &failed_cache);
    try std.testing.expectEqual(Status.failed, failed.status);
    try std.testing.expectEqual(Status.failed, failed_cache.lookup("build").?);

    // A log that claims completion without an artifact is a contradiction, and it
    // resolves to failure rather than to the log's word.
    var lying_cache = Cache.init(gpa);
    defer lying_cache.deinit();
    var lying = Action{ .name = "build", .status = .running };
    try pluginTerminated(&lying, &lying_cache);
    try reconcile(gpa, &lying, .{ .log = .completed }, &lying_cache);
    try std.testing.expectEqual(Status.failed, lying.status);

    // A log that shows the action began, with no artifact, is failure as well: it
    // ran and did not produce its result.
    var interrupted_cache = Cache.init(gpa);
    defer interrupted_cache.deinit();
    var interrupted = Action{ .name = "build", .status = .running };
    try pluginTerminated(&interrupted, &interrupted_cache);
    try reconcile(gpa, &interrupted, .{ .log = .started }, &interrupted_cache);
    try std.testing.expectEqual(Status.failed, interrupted.status);

    // No evidence at all: the status stays unknown and nothing is cached, so the
    // question remains open rather than being answered by default.
    var open_cache = Cache.init(gpa);
    defer open_cache.deinit();
    var open = Action{ .name = "build", .status = .running };
    try pluginTerminated(&open, &open_cache);
    try reconcile(gpa, &open, .{}, &open_cache);
    // The `.{}` above is absence of evidence in both fields.
    try std.testing.expectEqual(Status.unknown, open.status);
    try std.testing.expect(open_cache.lookup("build") == null);

    // Reconciling an action whose plugin did not die changes nothing: this path is
    // for crashes, not a general-purpose status setter.
    var healthy = Action{ .name = "build", .status = .running };
    try reconcile(gpa, &healthy, .{ .artifact_present_and_verified = true }, &open_cache);
    try std.testing.expectEqual(Status.running, healthy.status);
}
