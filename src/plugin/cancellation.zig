//! Cancelling an action that a plugin owns (M13, PLUGIN-005).
//!
//! Asking a plugin to stop is not the same as it having stopped. The plugin owns a
//! process tree, and the tree can still be writing files long after the request
//! arrives. If the core released the action's lease on the strength of the request,
//! collection could delete the working directory out from under a process that is
//! still running - the cancellation would cause the corruption it was meant to
//! prevent.
//!
//! So cancellation is a state the action passes through, not a state it lands in.
//! The lease is held through `cancelling` and is only releasable once the action is
//! terminal, which requires evidence that the tree is gone. A plugin that never
//! acknowledges leaves the action `cancelling` and the lease held, because that is
//! what is known; nothing is guessed to make the bookkeeping tidier.
const std = @import("std");

pub const Error = error{
    ActionNotTerminal,
    AlreadyTerminal,
    LeaseNotHeld,
    UnknownAction,
};

pub const Status = enum {
    running,
    /// Cancellation has been requested and the process tree has not been reported
    /// gone. The lease is still held.
    cancelling,
    cancelled,
    /// Finished on its own before the cancellation was acknowledged.
    completed,
};

pub const Action = struct {
    name: []const u8,
    status: Status = .running,
    /// Held while the action can still touch its working directory.
    lease_held: bool = true,
    /// The moment at which the tree was reported gone, for the record.
    reaped: bool = false,

    pub fn terminal(self: Action) bool {
        return self.status == .cancelled or self.status == .completed;
    }
};

/// Requests cancellation. The action enters `cancelling`; nothing is released.
pub fn requestCancel(action: *Action) Error!void {
    if (action.terminal()) return error.AlreadyTerminal;
    action.status = .cancelling;
}

/// Records that the process tree is gone. Only this makes the action terminal, and
/// only a terminal action may have its lease released.
pub fn reap(action: *Action, tree_exited: bool) Error!void {
    if (action.status != .cancelling) return error.ActionNotTerminal;
    if (!tree_exited) return error.ActionNotTerminal;
    action.reaped = true;
    // A tree that is gone before the cancellation was acknowledged either finished
    // its work or was stopped; from the core's side it was cancelled, and the
    // artifact evidence decides what the work achieved, not this state.
    action.status = .cancelled;
}

/// Releases the action's lease. Refused while the action is not terminal, because a
/// lease released early is a working directory that can be collected while a process
/// still writes to it.
pub fn releaseLease(action: *Action) Error!void {
    if (!action.lease_held) return error.LeaseNotHeld;
    if (!action.terminal()) return error.ActionNotTerminal;
    action.lease_held = false;
}

test "m13/PLUGIN-005 cancel external action: the lease survives until the tree is reconciled" {
    std.debug.print("JCKG_EVIDENCE PLUGIN-005\n", .{});
    const gpa = std.testing.allocator;

    var action = Action{ .name = "build" };
    // Held from the start: the action can touch its working directory.
    try std.testing.expect(action.lease_held);

    // Cancellation is requested. The action is not terminal, and the lease is still
    // held - this is the state a naive implementation collapses into "cancelled".
    try requestCancel(&action);
    try std.testing.expectEqual(Status.cancelling, action.status);
    try std.testing.expect(!action.terminal());
    try std.testing.expect(action.lease_held);

    // Releasing the lease now is refused: the process tree may still be writing.
    try std.testing.expectError(error.ActionNotTerminal, releaseLease(&action));
    try std.testing.expect(action.lease_held);

    // Releasing a lease that is not held is distinguished from that refusal.
    var released = Action{ .name = "other", .status = .completed, .lease_held = false };
    try std.testing.expectError(error.LeaseNotHeld, releaseLease(&released));

    // The tree is reported gone. Only now is the action terminal, and only now may
    // the lease be released.
    try reap(&action, true);
    try std.testing.expectEqual(Status.cancelled, action.status);
    try std.testing.expect(action.terminal());
    try std.testing.expect(action.reaped);
    try releaseLease(&action);
    try std.testing.expect(!action.lease_held);

    // A second release is refused rather than silently succeeding.
    try std.testing.expectError(error.LeaseNotHeld, releaseLease(&action));

    // A tree that has not exited is not reconciled: the action stays cancelling and
    // the lease stays held, because that is what is known.
    var pending = Action{ .name = "slow" };
    try requestCancel(&pending);
    try std.testing.expectError(error.ActionNotTerminal, reap(&pending, false));
    try std.testing.expectEqual(Status.cancelling, pending.status);
    try std.testing.expect(pending.lease_held);
    try std.testing.expectError(error.ActionNotTerminal, releaseLease(&pending));

    // Reaping an action that was never cancelling is refused: this path is for
    // cancellation, not a general-purpose status setter.
    var running = Action{ .name = "running" };
    try std.testing.expectError(error.ActionNotTerminal, reap(&running, true));
    try std.testing.expectEqual(Status.running, running.status);

    // Cancelling something already terminal is refused, so a completed action cannot
    // be rewritten into a cancelled one.
    var done = Action{ .name = "done", .status = .completed };
    try std.testing.expectError(error.AlreadyTerminal, requestCancel(&done));
    try std.testing.expectEqual(Status.completed, done.status);
    // A terminal action may release its lease immediately.
    try releaseLease(&done);

    // A plugin that dies while cancelling is reconciled the same way once the tree is
    // known to be gone: the core does not wait for a plugin that no longer exists.
    var crashed = Action{ .name = "crashed" };
    try requestCancel(&crashed);
    try reap(&crashed, true);
    try std.testing.expectEqual(Status.cancelled, crashed.status);
    try releaseLease(&crashed);
    _ = gpa;
}
