//! Recovering leases left by a crashed controller (M12, SPACE-004).
//!
//! A lease records who holds it so that a crash can be told apart from a live
//! holder. The case is about the two naive answers, both wrong:
//!
//! - **PID alone**: process identifiers are reused, so a lease whose holder died
//!   looks alive again the moment an unrelated process takes its number. Recovering
//!   on that basis would delete an *active* holder's work; refusing on that basis
//!   would keep a dead lease forever.
//! - **Time alone**: a fixed timeout cannot distinguish "crashed" from "slow", so it
//!   either deletes work that is still running or waits indefinitely.
//!
//! The answer is identity: a lease is stale when the *identity* it recorded - the
//! process identifier **and** the time that process started - is not among the
//! processes that exist now. A reused identifier fails that test because the start
//! time differs, which is exactly the discrimination a crash needs.
const std = @import("std");

pub const Error = error{
    DuplicateLease,
    OutOfMemory,
};

/// The identity a lease records. M03's process reconciliation uses the same two
/// facts for the same reason: a process is identified by when it started, not only
/// by the number it was given.
pub const Identity = struct {
    pid: u32,
    started_at: u64,
};

pub const Lease = struct {
    id: []const u8,
    holder: Identity,
};

/// A process observed to exist right now.
pub const Observed = struct {
    identity: Identity,
};

pub const Plan = struct {
    /// Leases whose holder identity is gone: safe to recover.
    stale: [][]const u8,
    /// Leases whose holder identity is present: recovery must leave them alone.
    live: [][]const u8,

    pub fn deinit(self: Plan, gpa: std.mem.Allocator) void {
        for (self.stale) |name| gpa.free(name);
        gpa.free(self.stale);
        for (self.live) |name| gpa.free(name);
        gpa.free(self.live);
    }
};

fn holderPresent(observed: []const Observed, holder: Identity) bool {
    for (observed) |entry| {
        // Both facts must match. A process that took over the identifier has a
        // different start time, so it does not vouch for this lease.
        if (entry.identity.pid == holder.pid and entry.identity.started_at == holder.started_at) return true;
    }
    return false;
}

/// Decides which leases may be recovered, given the processes that exist now.
pub fn recover(gpa: std.mem.Allocator, leases: []const Lease, observed: []const Observed) Error!Plan {
    for (leases, 0..) |lease, index| {
        for (leases[index + 1 ..]) |other| {
            if (std.mem.eql(u8, lease.id, other.id)) return error.DuplicateLease;
        }
    }

    var stale: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (stale.items) |name| gpa.free(name);
        stale.deinit(gpa);
    }
    var live: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (live.items) |name| gpa.free(name);
        live.deinit(gpa);
    }

    for (leases) |lease| {
        if (holderPresent(observed, lease.holder)) {
            try live.append(gpa, try gpa.dupe(u8, lease.id));
        } else {
            try stale.append(gpa, try gpa.dupe(u8, lease.id));
        }
    }
    return .{ .stale = try stale.toOwnedSlice(gpa), .live = try live.toOwnedSlice(gpa) };
}

test "m12/SPACE-004 recover stale lease: a reused PID does not keep a lease alive" {
    std.debug.print("JCKG_EVIDENCE SPACE-004\n", .{});
    const gpa = std.testing.allocator;

    // Four leases over four processes that exist right now:
    //   - `live` is held by a process that is still running (same pid, same start);
    //   - `crashed` is held by a process that is gone;
    //   - `reused` is held by a process that died, and an unrelated process has since
    //     taken its identifier with a different start time;
    //   - `other-live` is a second live holder, so the sweep has something to lose.
    const leases = [_]Lease{
        .{ .id = "live", .holder = .{ .pid = 1000, .started_at = 500 } },
        .{ .id = "crashed", .holder = .{ .pid = 2000, .started_at = 600 } },
        .{ .id = "reused", .holder = .{ .pid = 3000, .started_at = 700 } },
        .{ .id = "other-live", .holder = .{ .pid = 4000, .started_at = 800 } },
    };
    const observed = [_]Observed{
        .{ .identity = .{ .pid = 1000, .started_at = 500 } }, // the live holder
        .{ .identity = .{ .pid = 3000, .started_at = 900 } }, // a *different* process with a reused pid
        .{ .identity = .{ .pid = 4000, .started_at = 800 } }, // the second live holder
    };

    const plan = try recover(gpa, &leases, &observed);
    defer plan.deinit(gpa);

    // The live holders are untouched, including the one whose identifier was reused
    // by somebody else: the lease is about the process, not the number.
    try std.testing.expectEqual(@as(usize, 2), plan.live.len);
    try std.testing.expectEqualStrings("live", plan.live[0]);
    try std.testing.expectEqualStrings("other-live", plan.live[1]);

    // The crashed holder and the reused-identifier holder are both recoverable, and
    // the second is the case a naive PID check gets wrong in the dangerous
    // direction: it would have declared that lease live and never cleaned it up.
    try std.testing.expectEqual(@as(usize, 2), plan.stale.len);
    try std.testing.expectEqualStrings("crashed", plan.stale[0]);
    try std.testing.expectEqualStrings("reused", plan.stale[1]);

    // A naive check, for contrast: by PID alone, `reused` looks live because the
    // number exists. That is the mistake this module exists to avoid.
    var naive_thought_it_was_live = false;
    for (observed) |entry| {
        if (entry.identity.pid == 3000) naive_thought_it_was_live = true;
    }
    try std.testing.expect(naive_thought_it_was_live);
    try std.testing.expect(!holderPresent(&observed, leases[2].holder));

    // No observed processes at all: every lease is stale, which is what a machine
    // that rebooted looks like.
    const none = [_]Observed{};
    const all_stale = try recover(gpa, &leases, &none);
    defer all_stale.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), all_stale.stale.len);
    try std.testing.expectEqual(@as(usize, 0), all_stale.live.len);

    // Duplicate lease identifiers are refused: two records with one id cannot both
    // decide the same holder.
    const duplicated = [_]Lease{
        .{ .id = "lease", .holder = .{ .pid = 1, .started_at = 1 } },
        .{ .id = "lease", .holder = .{ .pid = 2, .started_at = 2 } },
    };
    try std.testing.expectError(error.DuplicateLease, recover(gpa, &duplicated, &none));
}
