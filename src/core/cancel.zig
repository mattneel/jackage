//! Cancellation for long-running client operations (case CLI-009).
//!
//! A user interrupt sets a token; long operations poll it and stop at a
//! defined point instead of being killed mid-write. The loop driver is
//! separated from the clock so a test can use a deterministic clock, while the
//! client uses the real monotonic clock.
const std = @import("std");

pub const Token = struct {
    flagged: std.atomic.Value(bool) = .init(false),

    pub fn request(self: *Token) void {
        self.flagged.store(true, .release);
    }

    pub fn isRequested(self: *const Token) bool {
        return self.flagged.load(.acquire);
    }

    pub fn check(self: *const Token) error{Canceled}!void {
        if (self.isRequested()) return error.Canceled;
    }
};

/// Monotonic nanosecond source. `context` is opaque so tests can inject a
/// deterministic counter instead of wall time.
pub const Clock = struct {
    context: ?*anyopaque = null,
    now_ns: *const fn (?*anyopaque) u64,

    pub fn now(self: Clock) u64 {
        return self.now_ns(self.context);
    }
};

fn ioNowNs(context: ?*anyopaque) u64 {
    const io_pointer: *const std.Io = @ptrCast(@alignCast(context orelse return 0));
    const stamp = std.Io.Timestamp.now(io_pointer.*, .awake);
    if (stamp.nanoseconds <= 0) return 0;
    const maximum: i96 = std.math.maxInt(u64);
    if (stamp.nanoseconds >= maximum) return std.math.maxInt(u64);
    return @intCast(stamp.nanoseconds);
}

/// A clock backed by the process's `Io`. `io` must outlive the loop.
pub fn clockForIo(io: *const std.Io) Clock {
    return .{ .context = @ptrCast(@constCast(io)), .now_ns = ioNowNs };
}

pub const Stop = enum {
    /// The operation ran to its declared end.
    completed,
    /// The caller requested cancellation.
    canceled,
    /// The declared time budget expired.
    deadline,
};

pub const Outcome = struct {
    stop: Stop,
    iterations: u64,
    elapsed_ns: u64,

    pub fn wasCanceled(self: Outcome) bool {
        return self.stop == .canceled;
    }
};

/// Drives a polled operation.
pub const Loop = struct {
    token: *const Token,
    clock: Clock,
    /// Hard iteration bound so a stuck step cannot spin forever.
    max_iterations: u64,
    /// Optional time budget in nanoseconds.
    deadline_ns: ?u64 = null,
    /// Number of iterations between deadline checks. The token is checked
    /// every iteration because a cancellation must be observed promptly.
    deadline_poll_interval: u64 = 8,

    /// Calls `step` until it returns false, the token is set, or the deadline
    /// passes. `step` must not perform irreversible work: the loop stops only
    /// at an iteration boundary.
    pub fn run(self: Loop, context: anytype, step: *const fn (@TypeOf(context), u64) bool) Outcome {
        const started = self.clock.now();
        var iteration: u64 = 0;
        while (iteration < self.max_iterations) : (iteration += 1) {
            if (self.token.isRequested()) {
                return .{ .stop = .canceled, .iterations = iteration, .elapsed_ns = self.clock.now() - started };
            }
            if (self.deadline_ns) |budget| {
                if (iteration % self.deadline_poll_interval == 0) {
                    if (self.clock.now() - started >= budget) {
                        return .{ .stop = .deadline, .iterations = iteration, .elapsed_ns = self.clock.now() - started };
                    }
                }
            }
            if (!step(context, iteration)) {
                return .{ .stop = .completed, .iterations = iteration + 1, .elapsed_ns = self.clock.now() - started };
            }
        }
        return .{ .stop = .completed, .iterations = iteration, .elapsed_ns = self.clock.now() - started };
    }
};

const FakeClock = struct {
    now: u64 = 0,
    step: u64 = 5 * std.time.ns_per_ms,

    fn read(context: ?*anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(context.?));
        const value = self.now;
        self.now += self.step;
        return value;
    }

    fn clock(self: *FakeClock) Clock {
        return .{ .context = @ptrCast(self), .now_ns = read };
    }
};

fn alwaysContinue(_: void, _: u64) bool {
    return true;
}

test "m01/CLI-009 respect cancellation" {
    std.debug.print("JCKG_EVIDENCE CLI-009\n", .{});
    const io = std.testing.io;

    // A real clock, a real second thread, and a token shared with it: the loop
    // must stop promptly with a cancellation outcome.
    var token: Token = .{};
    var io_local = io;
    const handle = try std.Thread.spawn(.{}, struct {
        fn run(shared: *Token) void {
            std.Io.Clock.Duration.sleep(
                .{ .raw = .{ .nanoseconds = 20 * std.time.ns_per_ms }, .clock = .awake },
                std.testing.io,
            ) catch {};
            shared.request();
        }
    }.run, .{&token});
    defer handle.join();

    const loop: Loop = .{
        .token = &token,
        .clock = clockForIo(&io_local),
        .max_iterations = 5_000_000_000,
    };
    const outcome = loop.run({}, alwaysContinue);

    try std.testing.expectEqual(Stop.canceled, outcome.stop);
    try std.testing.expect(outcome.wasCanceled());
    // Cancellation was observed long before the iteration bound, and the
    // operation still reports where it stopped.
    try std.testing.expect(outcome.iterations < 5_000_000_000);
    try std.testing.expect(outcome.elapsed_ns < 10 * std.time.ns_per_s);

    // Negative-or-recovery: a token set before the loop starts stops it at
    // iteration zero, and an unwatched loop completes normally.
    var pre_set: Token = .{};
    pre_set.request();
    try std.testing.expectError(error.Canceled, pre_set.check());
    var fake = FakeClock{};
    const pre_loop: Loop = .{ .token = &pre_set, .clock = fake.clock(), .max_iterations = 1000 };
    const pre_outcome = pre_loop.run({}, alwaysContinue);
    try std.testing.expectEqual(Stop.canceled, pre_outcome.stop);
    try std.testing.expectEqual(@as(u64, 0), pre_outcome.iterations);

    var quiet: Token = .{};
    var fake_quiet = FakeClock{};
    const quiet_loop: Loop = .{ .token = &quiet, .clock = fake_quiet.clock(), .max_iterations = 25 };
    const completed = quiet_loop.run({}, alwaysContinue);
    try std.testing.expectEqual(Stop.completed, completed.stop);
    try std.testing.expectEqual(@as(u64, 25), completed.iterations);

    // A step that reports completion stops the loop with the completed status.
    const StopAfterFive = struct {
        fn step(_: void, iteration: u64) bool {
            return iteration < 5;
        }
    };
    var fake_step = FakeClock{};
    const early_loop: Loop = .{ .token = &quiet, .clock = fake_step.clock(), .max_iterations = 1000 };
    const early = early_loop.run({}, StopAfterFive.step);
    try std.testing.expectEqual(Stop.completed, early.stop);
    try std.testing.expectEqual(@as(u64, 6), early.iterations);

    // The declared time budget is reported separately from a user cancel.
    var fake_deadline = FakeClock{};
    const deadline_loop: Loop = .{
        .token = &quiet,
        .clock = fake_deadline.clock(),
        .max_iterations = 1_000_000,
        .deadline_ns = 10 * std.time.ns_per_ms,
        .deadline_poll_interval = 1,
    };
    const timed_out = deadline_loop.run({}, alwaysContinue);
    try std.testing.expectEqual(Stop.deadline, timed_out.stop);
    try std.testing.expect(timed_out.iterations > 0);
    try std.testing.expect(timed_out.iterations < 1_000_000);
    try std.testing.expect(timed_out.elapsed_ns >= 10 * std.time.ns_per_ms);
}
