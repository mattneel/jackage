//! Linux counterpart to M03 native execution for profile runners. The same
//! lease ID and started/running/completed journal protocol applies. Launch is
//! std.process.spawn with an explicit executable, exact argv, empty declared
//! environment and a new process group. A crash between spawn and identity
//! persistence remains `started`/uncertain and never permits lease release.
//! Group members are recorded with PID + start ticks; cleanup verifies ordinary
//! group descendants and all observed identities stopped before completion.
//! Deliberate process-group escape is not prevented (native is not a sandbox).
const std = @import("std");
const builtin = @import("builtin");
const exec = @import("../exec/mod.zig");
const cancel = @import("../core/cancel.zig");
const process = @import("process.zig");

fn pause(io: std.Io) !void { try std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = 5 * std.time.ns_per_ms }, .clock = .awake }, io); }

const Capture = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: []u8,
    length: usize = 0,
    discarded: u64 = 0,
    failure: ?anyerror = null,
    finish: std.atomic.Value(bool) = .init(false),
    fn run(self: *Capture) void {
        var buffer: [8192]u8 = undefined;
        while (true) {
            const count = self.file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => return,
                error.WouldBlock => {
                    if (self.finish.load(.acquire)) return;
                    pause(self.io) catch |sleep_error| { self.failure = sleep_error; return; };
                    continue;
                },
                else => { self.failure = err; return; },
            };
            if (count == 0) return;
            const kept = @min(count, self.bytes.len - self.length);
            @memcpy(self.bytes[self.length..][0..kept], buffer[0..kept]);
            self.length += kept;
            self.discarded +|= count - kept;
        }
    }
};

fn nonblocking(file: *std.Io.File) !void {
    const flags = std.os.linux.fcntl(file.handle, std.os.linux.F.GETFL, 0);
    if (std.os.linux.errno(flags) != .SUCCESS) return error.PipeFlagsUnavailable;
    const rc = std.os.linux.fcntl(file.handle, std.os.linux.F.SETFL, flags | @as(u32, @bitCast(@as(std.os.linux.O, .{ .NONBLOCK = true }))));
    if (std.os.linux.errno(rc) != .SUCCESS) return error.PipeFlagsUnavailable;
    file.flags.nonblocking = true;
}

fn observe(io: std.Io, gpa: std.mem.Allocator, root: process.Identity, owned: *std.ArrayList(process.Identity)) !bool {
    const members = try process.groupMembers(io, gpa, root.pid);
    defer gpa.free(members);
    var changed = false;
    for (members) |member| {
        if (member.pid == root.pid and member.created == root.created) continue;
        var found = false;
        for (owned.items) |prior| if (prior.pid == member.pid and prior.created == member.created) { found = true; break; };
        if (!found) { try owned.append(gpa, member); changed = true; }
    }
    return changed;
}

fn stopped(io: std.Io, gpa: std.mem.Allocator, root: process.Identity, owned: []const process.Identity) bool {
    if (process.state(io, gpa, root) != .gone) return false;
    for (owned) |identity| if (process.state(io, gpa, identity) != .gone) return false;
    const members = process.groupMembers(io, gpa, root.pid) catch return false;
    defer gpa.free(members);
    return members.len == 0;
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, journal: exec.Journal, request: exec.Request, token: *const cancel.Token) !exec.Result {
    if (builtin.os.tag != .linux) return error.ProfilePlatformUnavailable;
    const stdout = try gpa.alloc(u8, request.log_budget / 2 + request.log_budget % 2);
    errdefer gpa.free(stdout);
    const stderr = try gpa.alloc(u8, request.log_budget / 2);
    errdefer gpa.free(stderr);
    var result: exec.Result = .{ .gpa = gpa, .stdout_storage = stdout, .stderr_storage = stderr };
    var environment = std.process.Environ.Map.init(gpa);
    defer environment.deinit();
    for (request.environment) |variable| {
        if (!std.process.Environ.Map.validateKeyForPut(variable.name) or std.mem.indexOfScalar(u8, variable.value, 0) != null) return error.InvalidEnvironment;
        if (environment.get(variable.name) != null) return error.DuplicateEnvironmentVariable;
        try environment.put(variable.name, variable.value);
    }
    if (token.isRequested()) {
        result.status = .cancelled;
        try journal.record(.{ .action_id = request.action_id, .phase = .completed, .result_status = "cancelled" });
        return result;
    }
    const argv = try gpa.alloc([]const u8, request.argv.len + 1);
    defer gpa.free(argv);
    argv[0] = request.program;
    @memcpy(argv[1..], request.argv);
    try journal.record(.{ .action_id = request.action_id, .phase = .started });
    var child = std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = .cwd(), .path = request.program } },
        .argv = argv,
        .environ_map = &environment,
        .cwd = .{ .dir = request.workspace },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        result.status = .launch_failure;
        result.cause = err;
        try journal.record(.{ .action_id = request.action_id, .phase = .completed, .result_status = "launch_failure" });
        return result;
    };
    defer child.kill(io);
    result.cleanup_complete = false;
    const pid = child.id orelse return error.ProcessIdentityUnavailable;
    const root = process.forPid(io, gpa, @intCast(pid)) catch |err| {
        // Identity uncertainty is durable. Stopping the known child handle is
        // not proof that unseen descendants have ended; retain its lease.
        result.cause = err;
        return result;
    };
    result.process = root;
    var owned: std.ArrayList(process.Identity) = .empty;
    defer owned.deinit(gpa);
    var stdout_file = child.stdout orelse return error.DiagnosticPipeUnavailable;
    var stderr_file = child.stderr orelse return error.DiagnosticPipeUnavailable;
    child.stdout = null;
    child.stderr = null;
    defer stdout_file.close(io);
    defer stderr_file.close(io);
    var out: Capture = .{ .io = io, .file = stdout_file, .bytes = stdout };
    var err: Capture = .{ .io = io, .file = stderr_file, .bytes = stderr };
    var out_thread: ?std.Thread = null;
    var err_thread: ?std.Thread = null;
    nonblocking(&out.file) catch |failure| { result.cause = failure; };
    nonblocking(&err.file) catch |failure| { result.cause = failure; };
    journal.record(.{ .action_id = request.action_id, .phase = .running, .process = root }) catch |failure| { result.cause = failure; };
    if (result.cause == null) {
        out_thread = std.Thread.spawn(.{}, Capture.run, .{&out}) catch |failure| blk: { result.cause = failure; break :blk null; };
        err_thread = std.Thread.spawn(.{}, Capture.run, .{&err}) catch |failure| blk: { result.cause = failure; break :blk null; };
    }
    const started = std.Io.Timestamp.now(io, .awake);
    if (result.cause == null) monitor: while (true) {
        if (token.isRequested()) { result.status = .cancelled; break; }
        if (request.deadline_ns) |deadline| if (std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds >= deadline) { result.status = .timeout; break; };
        const changed = observe(io, gpa, root, &owned) catch |failure| { result.cause = failure; break; };
        if (changed) journal.record(.{ .action_id = request.action_id, .phase = .running, .process = root, .descendants = owned.items }) catch |failure| { result.cause = failure; break :monitor; };
        switch (process.state(io, gpa, root)) {
            .gone => break,
            .unknown => { result.cause = error.ProcessStateUncertain; break; },
            .live => {},
        }
        pause(io) catch |failure| { result.cause = failure; break; };
    };
    _ = observe(io, gpa, root, &owned) catch {};
    process.stopGroup(root.pid) catch |failure| if (failure != error.ProcessNotFound) { result.cause = failure; };
    for (owned.items) |identity| process.stop(identity, io, gpa) catch |failure| { result.cause = failure; };
    const term = child.wait(io) catch |failure| blk: { result.cause = failure; break :blk null; };
    if (term) |termination| {
        result.exit_code = switch (termination) {
            .exited => |code| code,
            .signal => |signal| 128 + @as(u32, @intCast(@intFromEnum(signal))),
            else => null,
        };
        if (result.cause == null and result.status != .cancelled and result.status != .timeout) result.status = if (result.exit_code == 0) .success else .action_failure;
    }
    for (0..2000) |_| {
        if (stopped(io, gpa, root, owned.items)) { result.cleanup_complete = true; break; }
        pause(io) catch break;
    }
    out.finish.store(true, .release);
    err.finish.store(true, .release);
    if (out_thread) |thread| thread.join();
    if (err_thread) |thread| thread.join();
    result.stdout = stdout[0..out.length];
    result.stderr = stderr[0..err.length];
    result.stdout_discarded = out.discarded;
    result.stderr_discarded = err.discarded;
    if (out.failure) |failure| result.cause = failure else if (err.failure) |failure| result.cause = failure;
    if (result.cause != null or !result.cleanup_complete) result.status = .infrastructure;
    journal.record(.{ .action_id = request.action_id, .phase = if (result.cleanup_complete) .completed else .running, .process = root, .descendants = owned.items, .result_status = @tagName(result.status) }) catch |failure| { result.cause = failure; result.status = .infrastructure; };
    return result;
}
