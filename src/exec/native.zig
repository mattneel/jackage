//! Real native Windows actions. This backend is not a sandbox.
//!
//! Actions use an explicit executable and argv, an empty environment map
//! populated only from the request, and a controller-owned durable journal.
//! Suspended launch records process identity before user code can run. Every
//! return after launch first attempts to stop and verify the observed tree.
//! A false cleanup_complete retains journal ownership and forbids lease release.
const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("../core/cancel.zig");
const capabilities = @import("../core/capabilities.zig");
const store_module = @import("../core/store.zig");
const collector = @import("collector.zig");
const journal_module = @import("journal.zig");
const windows = @import("windows.zig");

pub const Environment = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    action_id: []const u8,
    /// Absolute executable path. There is no shell or ambient PATH resolution.
    program: []const u8,
    /// Arguments excluding argv[0]; every boundary is passed unchanged.
    argv: []const []const u8 = &.{},
    /// No platform minimum is added implicitly. Declare SystemRoot/PATH if
    /// the selected tool needs them; cmd may itself synthesize local variables.
    environment: []const Environment = &.{},
    workspace: std.Io.Dir,
    outputs: []const []const u8 = &.{},
    /// Relative monotonic time budget from successful resume, in nanoseconds.
    deadline_ns: ?u64 = null,
    /// Total captured byte budget: ceil(half) stdout, floor(half) stderr.
    /// Both streams continue draining after their assigned capture cap.
    log_budget: usize = 64 * 1024,
    /// Strict restrictions require `enforced`, not merely `supported`.
    /// Missing/native-unavailable requirements return CapabilityUnavailable.
    strict_capabilities: []const []const u8 = &.{},
};

pub const Status = enum { success, action_failure, launch_failure, cancelled, timeout, infrastructure };

pub const Result = struct {
    status: Status = .infrastructure,
    /// Set only after a real process exit, including termination by taskkill.
    /// Uses the full Windows DWORD exit code rather than Zig's u8 Term field.
    exit_code: ?u32 = null,
    process: ?windows.Identity = null,
    stdout: []const u8 = &.{},
    stderr: []const u8 = &.{},
    stdout_discarded: u64 = 0,
    stderr_discarded: u64 = 0,
    outputs: ?collector.Collection = null,
    cause: ?anyerror = null,
    /// No caller may release a workspace/store lease while this is false.
    cleanup_complete: bool = true,
    stdout_storage: []u8,
    stderr_storage: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        if (self.outputs) |*outputs| outputs.deinit();
        self.gpa.free(self.stdout_storage);
        self.gpa.free(self.stderr_storage);
        self.* = undefined;
    }
};

const native_capabilities = [_]capabilities.Capability{
    .{ .name = "process.argv", .status = .supported, .evidence = "EXE-001 real client receives exact tokens via explicit executable and argv; no implicit shell", .blocks_release = false },
    .{ .name = "environment.declared", .status = .supported, .evidence = "EXE-002 child environment map starts empty; only caller-declared entries are supplied", .blocks_release = false },
    .{ .name = "filesystem.isolation", .status = .unavailable, .evidence = "native processes retain the caller's filesystem authority; output validation is not filesystem isolation", .blocks_release = true },
    .{ .name = "network.isolation", .status = .unavailable, .evidence = "same network access as the controller; no network restriction is installed", .blocks_release = true },
    .{ .name = "resources.bounds", .status = .unavailable, .evidence = "no OS-enforced CPU/memory limits; a polled deadline is not an enforced resource sandbox", .blocks_release = true },
    .{ .name = "process.cleanup", .status = .supported, .evidence = "EXE-007 verifies observed child/grandchild identities gone after taskkill /T /F; no job object, no guarantee against detached children or snapshot/spawn races", .blocks_release = true },
    .{ .name = "output.collection", .status = .supported, .evidence = "EXE-003/004 collect declared paths only, reject traversal and reparse points before publication; same-user mutation is not isolated", .blocks_release = false },
    .{ .name = "diagnostics.bounded", .status = .supported, .evidence = "EXE-009 concurrently drains stdout/stderr through fixed-size buffers and a fixed total capture budget", .blocks_release = false },
    .{ .name = "controller.reconciliation", .status = .supported, .evidence = "EXE-010 durable journal reconciles PID plus creation time; live or uncertain records refuse retry", .blocks_release = false },
    .{ .name = "paths.stable_logical", .status = .supported, .evidence = "collected tree entries use relative portable paths and content digests", .blocks_release = false },
    .{ .name = "workspace.reclamation", .status = .unavailable, .evidence = "executor does not implement automatic workspace reclamation; caller must honor cleanup_complete and journal ownership", .blocks_release = true },
    .{ .name = "process.spawn", .status = .supported, .evidence = "exact Windows CreateProcessW application name and CRT argv encoding; no pinned-std ambient PATHEXT or batch-shell fallback; std.process.Child wait/kill lifecycle retained", .blocks_release = false },
};

const unavailable_platform_capabilities = block: {
    var report = native_capabilities;
    for (&report) |*capability| {
        if (capability.status == .supported) {
            capability.status = .unavailable;
            capability.evidence = "this native executor implements Windows process ownership only; this target is refused with NativePlatformUnavailable, not silently executed without lifecycle guarantees";
            capability.blocks_release = true;
        }
    }
    break :block report;
};

pub fn nativeBackend() capabilities.Backend {
    const baseline = capabilities.nativeProcessBackend();
    return .{ .name = baseline.name, .family = baseline.family, .isolation_boundary = baseline.isolation_boundary, .capabilities = if (builtin.os.tag == .windows) &native_capabilities else &unavailable_platform_capabilities };
}

/// Policy never silently falls back from a strict requirement to native.
pub fn requireCapabilities(required: []const []const u8) error{CapabilityUnavailable}!void {
    const backend = nativeBackend();
    for (required) |name| {
        const capability = backend.find(name) orelse return error.CapabilityUnavailable;
        if (capability.status != .enforced) return error.CapabilityUnavailable;
    }
}

const Capture = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: []u8,
    length: usize = 0,
    discarded: u64 = 0,
    failure: ?anyerror = null,
    finish: std.atomic.Value(bool) = .init(false),

    fn drain(self: *Capture) void {
        var buffer: [8192]u8 = undefined;
        while (true) {
            const available = windows.pipeAvailable(self.file) catch |err| {
                self.failure = err;
                return;
            } orelse return;
            if (available == 0) {
                if (self.finish.load(.acquire)) return;
                pause(self.io, std.time.ns_per_ms) catch |err| {
                    self.failure = err;
                    return;
                };
                continue;
            }
            const count = self.file.readStreaming(self.io, &.{buffer[0..@min(buffer.len, available)]}) catch |err| {
                if (err != error.EndOfStream) self.failure = err;
                return;
            };
            if (count == 0) continue;
            const kept = @min(count, self.bytes.len - self.length);
            @memcpy(self.bytes[self.length..][0..kept], buffer[0..kept]);
            self.length += kept;
            self.discarded +|= count - kept;
        }
    }
};

fn pause(io: std.Io, nanoseconds: u64) !void {
    try std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = nanoseconds }, .clock = .awake }, io);
}

pub const Executor = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    store: store_module.Store,
    journal: journal_module.Journal,

    /// Startup reconciliation never guesses that a record's PID is still the
    /// same process. The caller retains live/uncertain ownership before retry.
    pub fn reconcile(self: Executor) !journal_module.Reconciliation {
        return self.journal.reconcileAll();
    }

    fn observe(self: Executor, process: windows.Identity, owned: *std.ArrayList(windows.Identity)) !bool {
        const found = try windows.discoverDescendants(self.gpa, process);
        defer self.gpa.free(found);
        var changed = false;
        for (found) |candidate| {
            var exists = false;
            for (owned.items) |prior| {
                if (prior.pid == candidate.pid and prior.created == candidate.created) exists = true;
            }
            if (!exists) {
                try owned.append(self.gpa, candidate);
                changed = true;
            }
        }
        return changed;
    }

    /// Address the root first while its parent links still exist, then any
    /// tracked survivor. Do not announce completion until every identity is gone.
    fn stopOwned(self: Executor, process: windows.Identity, owned: *std.ArrayList(windows.Identity)) bool {
        _ = self.observe(process, owned) catch {};
        windows.taskkill(self.gpa, self.io, process) catch {};
        for (owned.items) |descendant| windows.taskkill(self.gpa, self.io, descendant) catch {};
        const start = std.Io.Timestamp.now(self.io, .awake);
        while (true) {
            var all_gone = windows.state(process) == .gone;
            for (owned.items) |descendant| {
                if (windows.state(descendant) != .gone) all_gone = false;
            }
            if (all_gone) return true;
            if (std.Io.Timestamp.now(self.io, .awake).nanoseconds - start.nanoseconds >= 5 * std.time.ns_per_s) return false;
            pause(self.io, 10 * std.time.ns_per_ms) catch return false;
        }
    }

    pub fn run(self: Executor, request: Request, token: *const cancel.Token) !Result {
        try requireCapabilities(request.strict_capabilities);
        if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
        if (!std.fs.path.isAbsolute(request.program)) return error.ProgramMustBeAbsolute;
        const previous = try self.journal.reconcile(request.action_id);
        if (!previous.safe_to_retry) {
            return if (previous.process_state == .live or previous.live_descendants != 0) error.ActionAlreadyRunning else error.ActionStateUncertain;
        }
        const stdout_storage = try self.gpa.alloc(u8, request.log_budget / 2 + request.log_budget % 2);
        errdefer self.gpa.free(stdout_storage);
        const stderr_storage = try self.gpa.alloc(u8, request.log_budget / 2);
        var result: Result = .{ .gpa = self.gpa, .stdout_storage = stdout_storage, .stderr_storage = stderr_storage };
        // From here, result owns all buffers even on an infrastructure result.
        errdefer self.gpa.free(stderr_storage);
        if (token.isRequested()) {
            result.status = .cancelled;
            try self.journal.record(.{ .action_id = request.action_id, .phase = .completed, .result_status = @tagName(result.status) });
            return result;
        }
        var environment = std.process.Environ.Map.init(self.gpa);
        defer environment.deinit();
        for (request.environment) |variable| {
            if (!std.process.Environ.Map.validateKeyForPut(variable.name) or std.mem.indexOfScalar(u8, variable.value, 0) != null) return error.InvalidEnvironment;
            if (environment.get(variable.name) != null) return error.DuplicateEnvironmentVariable;
            try environment.put(variable.name, variable.value);
        }
        const argv = try self.gpa.alloc([]const u8, request.argv.len + 1);
        defer self.gpa.free(argv);
        argv[0] = request.program;
        @memcpy(argv[1..], request.argv);
        try self.journal.record(.{ .action_id = request.action_id, .phase = .started });
        var child = windows.spawnExact(self.gpa, self.io, .{
            .program = request.program,
            .argv = argv,
            .cwd = request.workspace,
            .environment = &environment,
        }) catch |err| {
            result.status = .launch_failure;
            result.cause = err;
            self.journal.record(.{ .action_id = request.action_id, .phase = .completed, .result_status = @tagName(result.status) }) catch |record_error| {
                result.status = .infrastructure;
                result.cause = record_error;
            };
            return result;
        };
        defer child.kill(self.io);
        result.cleanup_complete = false;
        const handle = child.id orelse {
            result.cause = error.ProcessIdentityUnavailable;
            return result;
        };
        const process = windows.identity(handle) catch |err| {
            child.kill(self.io);
            result.cleanup_complete = true;
            result.cause = err;
            return result;
        };
        result.process = process;
        var owned: std.ArrayList(windows.Identity) = .empty;
        defer owned.deinit(self.gpa);
        self.journal.record(.{ .action_id = request.action_id, .phase = .running, .process = process }) catch |err| {
            result.cleanup_complete = self.stopOwned(process, &owned);
            result.cause = err;
            return result;
        };
        const stdout_file = child.stdout orelse {
            result.cleanup_complete = self.stopOwned(process, &owned);
            result.cause = error.DiagnosticPipeUnavailable;
            return result;
        };
        const stderr_file = child.stderr orelse {
            result.cleanup_complete = self.stopOwned(process, &owned);
            result.cause = error.DiagnosticPipeUnavailable;
            return result;
        };
        // Transfer pipe ownership; Child.wait must not close a drainer's handle.
        child.stdout = null;
        child.stderr = null;
        defer stdout_file.close(self.io);
        defer stderr_file.close(self.io);
        var out: Capture = .{ .io = self.io, .file = stdout_file, .bytes = stdout_storage };
        var err: Capture = .{ .io = self.io, .file = stderr_file, .bytes = stderr_storage };
        const out_thread = std.Thread.spawn(.{}, Capture.drain, .{&out}) catch |spawn_error| {
            result.cleanup_complete = self.stopOwned(process, &owned);
            result.cause = spawn_error;
            return result;
        };
        const err_thread = std.Thread.spawn(.{}, Capture.drain, .{&err}) catch |spawn_error| {
            result.cleanup_complete = self.stopOwned(process, &owned);
            out.finish.store(true, .release);
            out_thread.join();
            result.cause = spawn_error;
            return result;
        };
        var resumed = false;
        windows.resumeProcess(child.thread_handle) catch |resume_error| {
            result.cause = resume_error;
        };
        if (result.cause == null) resumed = true;
        const started = std.Io.Timestamp.now(self.io, .awake);
        if (resumed) monitor: while (true) {
            if (token.isRequested()) {
                result.status = .cancelled;
                break;
            }
            if (request.deadline_ns) |deadline| {
                if (std.Io.Timestamp.now(self.io, .awake).nanoseconds - started.nanoseconds >= deadline) {
                    result.status = .timeout;
                    break;
                }
            }
            const changed = self.observe(process, &owned) catch |observe_error| {
                result.cause = observe_error;
                break;
            };
            if (changed) self.journal.record(.{ .action_id = request.action_id, .phase = .running, .process = process, .descendants = owned.items }) catch |record_error| {
                result.cause = record_error;
                break :monitor;
            };
            const finished = windows.isFinished(handle) catch |state_error| {
                result.cause = state_error;
                break;
            };
            if (finished) {
                result.exit_code = windows.exitCode(handle) catch |exit_error| {
                    result.cause = exit_error;
                    break;
                };
                result.status = if (result.exit_code == 0) .success else .action_failure;
                break;
            }
            pause(self.io, 10 * std.time.ns_per_ms) catch |sleep_error| {
                result.cause = sleep_error;
                break;
            };
        };
        result.cleanup_complete = self.stopOwned(process, &owned);
        if (!result.cleanup_complete) {
            result.status = .infrastructure;
            result.cause = error.ProcessTreeCleanupFailed;
            // Preserve identities, never label unfinished ownership completed.
            self.journal.record(.{ .action_id = request.action_id, .phase = .running, .process = process, .descendants = owned.items }) catch {};
        } else {
            if (result.exit_code == null) result.exit_code = windows.exitCode(handle) catch null;
            if (child.wait(self.io)) |_| {} else |wait_error| {
                result.status = .infrastructure;
                result.cause = wait_error;
            }
        }
        out.finish.store(true, .release);
        err.finish.store(true, .release);
        out_thread.join();
        err_thread.join();
        result.stdout = stdout_storage[0..out.length];
        result.stderr = stderr_storage[0..err.length];
        result.stdout_discarded = out.discarded;
        result.stderr_discarded = err.discarded;
        const capture_failure: ?anyerror = if (out.failure != null) out.failure else err.failure;
        if (capture_failure) |capture_error| {
            result.status = .infrastructure;
            result.cause = capture_error;
        }
        if (result.status == .success) {
            result.outputs = collector.collect(self.gpa, self.io, request.workspace, request.outputs, self.store) catch |collection_error| {
                result.status = .infrastructure;
                result.cause = collection_error;
                return self.finish(request, result, owned.items);
            };
        }
        return self.finish(request, result, owned.items);
    }

    fn finish(self: Executor, request: Request, value: Result, owned: []const windows.Identity) Result {
        var result = value;
        if (!result.cleanup_complete) return result;
        self.journal.record(.{ .action_id = request.action_id, .phase = .completed, .process = result.process, .descendants = owned, .result_status = @tagName(result.status) }) catch |record_error| {
            if (result.outputs) |*outputs| outputs.deinit();
            result.outputs = null;
            result.status = .infrastructure;
            result.cause = record_error;
        };
        return result;
    }
};
