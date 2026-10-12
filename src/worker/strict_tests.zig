//! Guest integration tests for the strict execution backend (M08).
//!
//! These are the tests that must run **inside the declared Linux execution
//! environment** (`scripts/wsl-evidence.ps1`): they start the real worker under
//! real namespaces and then attempt the violations a sandbox is supposed to
//! prevent. On a platform without namespaces each test asserts the *refusal*
//! path instead, so a green host run never implies a sandbox that was never
//! applied.
//!
//! The action in every case is `jckg-probe` - a real process launched through
//! the worker exactly like any other action, so the checks observe the sandbox
//! from the inside rather than trusting it.
const std = @import("std");
const builtin = @import("builtin");
const frames = @import("frames.zig");
const auth = @import("auth.zig");
const sandbox = @import("sandbox.zig");
const worker = @import("main.zig");
const controller = @import("controller.zig");

const testing = std.testing;

/// Where the guest build puts the worker and the probe. The guest suite runs
/// from the checkout root (the Mutagen mirror, ADR-0002), so these are relative.
pub const worker_binary = "zig-out/bin/jckg-worker";
pub const probe_binary = "zig-out/bin/jckg-probe";
/// The namespace helper, by absolute path: it is a property of the declared
/// environment, not something the test should be able to silently mis-resolve.
pub const unshare_path = "/usr/bin/unshare";

/// A case's observable result: what the worker reported and what the probe saw.
pub const Outcome = struct {
    status: ?u32,
    events: []const u8,
    response: []const u8,

    pub fn deinit(self: Outcome, gpa: std.mem.Allocator) void {
        gpa.free(self.events);
        gpa.free(self.response);
    }
};

/// Drives one sandboxed probe run: spawn the worker under `unshare`, perform the
/// handshake and authentication, request the probe, and collect what came back.
pub fn runProbe(
    gpa: std.mem.Allocator,
    io: std.Io,
    check_name: []const u8,
    workspace: []const u8,
    store: []const u8,
    host_checkout: []const u8,
) !Outcome {
    if (builtin.os.tag != .linux) return error.SandboxUnavailable;

    // The binds need real directories on both sides: the host paths the plan
    // names, and the mount point the worker builds its tree under.
    for ([_][]const u8{ workspace, store, "/jckg" }) |path| {
        std.Io.Dir.createDirAbsolute(io, path, std.Io.File.Permissions.default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // The plan names host paths, and a plan is a description of absolute
    // locations: a relative source would make the bind depend on the worker's
    // working directory, which is a property the plan cannot state.
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const worker_path = try std.fs.path.join(gpa, &.{ cwd, worker_binary });
    defer gpa.free(worker_path);
    const probe_path = try std.fs.path.join(gpa, &.{ cwd, probe_binary });
    defer gpa.free(probe_path);

    const preamble = try sandbox.namespacePreamble(gpa, worker_path, "/dev/null", .none);
    defer {
        for (preamble) |entry| gpa.free(entry);
        gpa.free(preamble);
    }

    // The worker's own argv is exactly the preamble plus its one flag. The
    // check belongs to the *action* and travels in the plan, not here: a worker
    // that accepted stray arguments would let a caller smuggle behaviour past
    // the declared plan.
    var argv = try gpa.alloc([]const u8, preamble.len + 2);
    defer gpa.free(argv);
    for (preamble, 0..) |entry, index| argv[index] = entry;
    argv[preamble.len] = "--sandbox";
    argv[preamble.len + 1] = "/dev/null";

    // The worker is spawned as `unshare`, which is resolved through PATH, so
    // the harness environment must carry one. The *action's* environment is a
    // separate thing entirely: it comes from the plan and is empty unless the
    // plan declares entries.
    var environment = std.process.Environ.Map.init(gpa);
    defer environment.deinit();
    try environment.put("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin");
    var child = std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = unshare_path } },
        .argv = argv,
        .environ_map = &environment,
        .cwd = .{ .dir = std.Io.Dir.cwd() },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        // Surface the child's own failure: a spawn error here means the
        // namespace helper never started, which is a harness problem, not a
        // sandbox finding.
        std.debug.print("harness: spawning the namespace helper failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer child.kill(io);

    var stdout_file = child.stdout orelse return error.DiagnosticPipeUnavailable;
    var stderr_file = child.stderr orelse return error.DiagnosticPipeUnavailable;
    child.stdout = null;
    child.stderr = null;

    // The worker's diagnostics are the only account of where it is, and they are
    // only useful while it is still running. Draining stderr on its own thread and
    // printing each line as it arrives turns "it hangs" into "it stopped after
    // line N" - which is the difference between guessing and knowing.
    const Diagnostics = struct {
        fn drain(file: *std.Io.File, stream_io: std.Io) void {
            var buffer: [4096]u8 = undefined;
            var reader = file.reader(stream_io, &buffer);
            while (true) {
                const line = reader.interface.takeDelimiterExclusive('\n') catch return;
                if (line.len == 0) continue;
                std.debug.print("worker said: {s}\n", .{line});
            }
        }
    };
    // Detached on purpose: the thread ends when the worker's stderr closes, and
    // joining it here made the harness wait on a pipe rather than on the worker.
    _ = std.Thread.spawn(.{}, Diagnostics.drain, .{ &stderr_file, io }) catch null;
    defer stdout_file.close(io);
    defer stderr_file.close(io);

    // The controller speaks the protocol to the worker. The token is minted
    // with a session secret the worker reads from the first line of its stdin.
    const secret = "guest-harness-secret-material!!";
    const token = try auth.issue(gpa, secret[0..32], .{
        .session = "guest-session",
        .worker = "jckg-worker",
        .expires = "2099-01-01T00:00:00Z",
    });
    var secret_line: [65]u8 = undefined;
    _ = try std.fmt.bufPrint(&secret_line, "{x}\n", .{secret[0..32].*});

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_writer = child.stdin.?.writer(io, &stdin_buffer);
    try stdin_writer.interface.writeAll(&secret_line);
    try stdin_writer.interface.flush();

    var frame_buffer: [64 * 1024]u8 = undefined;
    var stdout_reader = stdout_file.reader(io, &frame_buffer);
    const in = &stdout_reader.interface;

    // Handshake: the worker answers with its identity and its claims.
    try worker.writeFrame(gpa, &stdin_writer.interface, .{ .handshake = .{ .session = "guest-session" } });
    try stdin_writer.interface.flush();
    std.debug.print("harness: sent secret and handshake, awaiting the worker's\n", .{});
    const answered = (try worker.readFrame(gpa, in, &frame_buffer)) orelse return error.NoResponse;
    std.debug.print("harness: handshake answered\n", .{});
    defer answered.deinit(gpa);
    switch (answered) {
        .handshake => |handshake| {
            if (handshake.major != frames.protocol_major) return error.UnsupportedProtocol;
            if (!std.mem.eql(u8, handshake.session, "guest-session")) return error.Unauthenticated;
        },
        else => return error.UnexpectedFrame,
    }

    // Authentication, then the run request.
    const token_json = try worker.encodeToken(gpa, token);
    defer gpa.free(token_json);
    try worker.writeFrame(gpa, &stdin_writer.interface, .{ .request = .{ .id = 1, .method = "auth", .parameters = token_json } });
    try stdin_writer.interface.flush();
    std.debug.print("harness: sent auth, awaiting the response\n", .{});
    const auth_response = (try worker.readFrame(gpa, in, &frame_buffer)) orelse return error.NoResponse;
    std.debug.print("harness: authenticated\n", .{});
    defer auth_response.deinit(gpa);
    switch (auth_response) {
        .response => |response| if (response.error_code != null) return error.Unauthenticated,
        else => return error.UnexpectedFrame,
    }

    // The plan carries the probe as a read-only bind at a fixed logical path, so
    // the action runs from inside the sandbox's own tree rather than from the
    // host filesystem; `host-path-hidden` takes the host path as its argument.
    const parameters = if (std.mem.eql(u8, check_name, "host-path-hidden"))
        try std.fmt.allocPrint(gpa,
            "{{\"action\":1,\"plan\":{{\"argv\":[\"/jckg/tools/probe\",\"{s}\",\"{s}\"],\"binds\":[{{\"source\":\"{s}\",\"target\":\"/jckg/tools/probe\",\"writable\":false}}],\"store\":\"{s}\",\"workspace\":\"{s}\"}}}}",
            .{ check_name, host_checkout, probe_path, store, workspace })
    else
        try std.fmt.allocPrint(gpa,
            "{{\"action\":1,\"plan\":{{\"argv\":[\"/jckg/tools/probe\",\"{s}\"],\"binds\":[{{\"source\":\"{s}\",\"target\":\"/jckg/tools/probe\",\"writable\":false}}],\"store\":\"{s}\",\"workspace\":\"{s}\"}}}}",
            .{ check_name, probe_path, store, workspace });
    defer gpa.free(parameters);
    try worker.writeFrame(gpa, &stdin_writer.interface, .{ .request = .{ .id = 2, .method = "run", .parameters = parameters } });
    try stdin_writer.interface.flush();
    // The worker serves until its input ends, so the harness closes the pipe
    // once the last request is sent. Without this the worker waits for commands
    // that will never come, and the test waits with it.
    if (child.stdin) |stdin_file| {
        stdin_file.close(io);
        child.stdin = null;
    }

    // A hard deadline around the whole exchange. A test that can hang forever
    // cannot report anything about what it is testing, and the worker's
    // diagnostics only become readable once it stops: the deadline kills the
    // worker so the harness finishes, prints what it saw, and reads stderr.
    const Deadline = struct {
        fn run(pid: i32) void {
            var duration = std.os.linux.timespec{ .sec = 45, .nsec = 0 };
            _ = std.os.linux.nanosleep(&duration, null);
            _ = std.os.linux.kill(pid, .KILL);
        }
    };
    // Detached too: joining it made every run wait out the full deadline even
    // when the worker had already exited, which turned a fast suite into a slow
    // one and hid where the real time went.
    const worker_pid: i32 = @intCast(child.id orelse 0);
    _ = std.Thread.spawn(.{}, Deadline.run, .{worker_pid}) catch null;

    std.debug.print("harness: sent run, reading events\n", .{});
    var events: std.Io.Writer.Allocating = .init(gpa);
    errdefer events.deinit();
    var response_text: []u8 = &.{};
    while (true) {
        const frame = (try worker.readFrame(gpa, in, &frame_buffer)) orelse break;
        if (frame == .event) {
            const line = try frames.encodeAlloc(gpa, frame);
            defer gpa.free(line);
            try events.writer.writeAll(line);
            try events.writer.writeByte('\n');
            frame.deinit(gpa);
            continue;
        }
        if (frame == .response) {
            if (frame.response.error_code) |code| {
                response_text = try gpa.dupe(u8, code);
            } else if (frame.response.result) |result| {
                response_text = try gpa.dupe(u8, result);
            } else {
                response_text = try gpa.dupe(u8, "{}");
            }
            std.debug.print("harness: response received\n", .{});
            frame.deinit(gpa);
            break;
        }
        frame.deinit(gpa);
    }

    std.debug.print("harness: waiting for the worker to exit\n", .{});
    const term = try child.wait(io);
    std.debug.print("harness: worker exited\n", .{});

    const status: ?u32 = switch (term) {
        .exited => |code| code,
        else => null,
    };
    return .{ .status = status, .events = try events.toOwnedSlice(), .response = response_text };
}

fn requireLinuxOrRefusal(comptime body: anytype) !void {
    if (builtin.os.tag != .linux) {
        // The strict backend refuses where it cannot be enforced. This is the
        // host-side assertion; the sandbox itself is exercised in the guest.
        try testing.expectError(error.SandboxUnavailable, body());
        return;
    }
    try body();
}

test "STRICT-001 deny undeclared filesystem: writes outside the declared set fail" {
    std.debug.print("JCKG_EVIDENCE STRICT-001\n", .{});
    try requireLinuxOrRefusal(struct {
        fn body() !void {
            const gpa = testing.allocator;
            const io = std.testing.io;
            // The action attempts three undeclared writes; every one must fail.
            var undeclared = try runProbe(gpa, io, "undeclared-write-denied", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer undeclared.deinit(gpa);
            std.debug.print("harness: status={?d} response={s} events={s}\n", .{ undeclared.status, undeclared.response, undeclared.events });
            try testing.expect(std.mem.indexOf(u8, undeclared.events, "\"name\":\"started\"") != null);
            try testing.expect(std.mem.indexOf(u8, undeclared.events, "\"name\":\"exited\"") != null);
            try testing.expect(std.mem.indexOf(u8, undeclared.events, "\"held\":true") != null);

            // Reads outside the declared roots must fail as well: the case is
            // about host-file *reads*, so a sandbox that only blocks writes
            // would pass a weaker test and leak the checkout.
            var read_denied = try runProbe(gpa, io, "undeclared-read-denied", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer read_denied.deinit(gpa);
            // Assert the verdict, not a substring of the prose: "was readable"
            // also occurs inside the *passing* detail "no host file was
            // readable", so the naive check failed a correct implementation.
            try testing.expect(std.mem.indexOf(u8, read_denied.events, "\"held\":true") != null);
            try testing.expect(std.mem.indexOf(u8, read_denied.events, "\"held\":false") == null);

            // The physical checkout is not reachable from inside, so an artifact
            // cannot record where it was built.
            var hidden = try runProbe(gpa, io, "host-path-hidden", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer hidden.deinit(gpa);
            try testing.expect(std.mem.indexOf(u8, hidden.events, "\"held\":true") != null);
        }
    }.body);
}

test "STRICT-002 deny network: only loopback exists in the sandbox" {
    std.debug.print("JCKG_EVIDENCE STRICT-002\n", .{});
    try requireLinuxOrRefusal(struct {
        fn body() !void {
            const gpa = testing.allocator;
            const io = std.testing.io;
            var outcome = try runProbe(gpa, io, "network-isolated", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer outcome.deinit(gpa);
            std.debug.print("harness: network events={s}\n", .{outcome.events});
            try testing.expect(std.mem.indexOf(u8, outcome.events, "\"held\":true") != null);
            try testing.expect(std.mem.indexOf(u8, outcome.events, "more than loopback is visible") == null);
        }
    }.body);
}

test "STRICT-003 isolate writable state: the declared root is writable, the store is not" {
    std.debug.print("JCKG_EVIDENCE STRICT-003\n", .{});
    try requireLinuxOrRefusal(struct {
        fn body() !void {
            const gpa = testing.allocator;
            const io = std.testing.io;
            // Exactly one writable location is expected: the declared workspace.
            var writable = try runProbe(gpa, io, "workspace-writable", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer writable.deinit(gpa);
            try testing.expect(std.mem.indexOf(u8, writable.events, "\"held\":true") != null);

            // The store is bound read-only, so a write attempt must be refused.
            var store = try runProbe(gpa, io, "store-read-only", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer store.deinit(gpa);
            try testing.expect(std.mem.indexOf(u8, store.events, "\"held\":true") != null);
            try testing.expect(std.mem.indexOf(u8, store.events, "store accepted a write") == null);
        }
    }.body);
}

test "STRICT-004 use stable logical paths: the action never sees host paths" {
    std.debug.print("JCKG_EVIDENCE STRICT-004\n", .{});
    try requireLinuxOrRefusal(struct {
        fn body() !void {
            const gpa = testing.allocator;
            const io = std.testing.io;

            // Same action, two different host workspaces: the logical path it
            // observes must be identical, which is what makes two builds
            // comparable.
            var first = try runProbe(gpa, io, "logical-paths", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer first.deinit(gpa);
            try testing.expect(std.mem.indexOf(u8, first.events, "/jckg/workspace") != null);
            try testing.expect(std.mem.indexOf(u8, first.events, "/tmp/jckg-test-workspace") == null);

            var second = try runProbe(gpa, io, "logical-paths", "/tmp/jckg-other-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer second.deinit(gpa);
            try testing.expect(std.mem.indexOf(u8, second.events, "/jckg/workspace") != null);
            try testing.expect(std.mem.indexOf(u8, second.events, "/tmp/jckg-other-workspace") == null);
        }
    }.body);
}

test "STRICT-005 enforce resources: the declared process limit refuses excess children" {
    std.debug.print("JCKG_EVIDENCE STRICT-005\n", .{});
    try requireLinuxOrRefusal(struct {
        fn body() !void {
            const gpa = testing.allocator;
            const io = std.testing.io;

            // The probe forks until the plan's limit refuses it; a limit that
            // accepts every child is not a limit.
            var limited = try runProbe(gpa, io, "resource-limit-enforced", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer limited.deinit(gpa);
            try testing.expect(std.mem.indexOf(u8, limited.events, "\"held\":true") != null);
            try testing.expect(std.mem.indexOf(u8, limited.events, "the limit accepted every child") == null);

            // The process namespace is what makes those limits observable: only
            // the action and its worker exist here.
            var isolated = try runProbe(gpa, io, "pid-isolated", "/tmp/jckg-test-workspace", "/tmp/jckg-test-store", "/mnt/c/src/jackage");
            defer isolated.deinit(gpa);
            try testing.expect(std.mem.indexOf(u8, isolated.events, "\"held\":true") != null);
        }
    }.body);
}

test "STRICT-010 a claimed capability the probe disproves is withdrawn" {
    std.debug.print("JCKG_EVIDENCE STRICT-010\n", .{});
    const gpa = testing.allocator;

    // The controller's rule, exercised directly: a worker that claims isolation
    // while the probe can violate it must lose the claim, not be trusted.
    const token = try auth.issue(gpa, "capability-probe-key-material!!", .{
        .session = "session-claims",
        .worker = "worker-claims",
        .expires = "2099-01-01T00:00:00Z",
    });

    var worker_output: std.Io.Writer.Allocating = .init(gpa);
    defer worker_output.deinit();
    const handshake = try frames.encodeAlloc(gpa, .{ .handshake = .{
        .capabilities = &.{"isolation.mount-namespace"},
        .session = "session-claims",
    } });
    defer gpa.free(handshake);
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try input.writer.writeAll(handshake);
    try input.writer.writeByte('\n');

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var reader = std.Io.Reader.fixed(input.written());
    const frame_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(frame_buffer);

    var under_test = controller.Controller.init(gpa, &output.writer, &reader, token, frame_buffer);
    defer under_test.deinit();
    try under_test.handshake(frames.protocol_major);

    // The probe attempted to write outside the workspace and succeeded, so the
    // claim is false.
    try controller.applyProbes(&under_test, &.{.{
        .name = "isolation.mount-namespace",
        .held = false,
        .detail = "wrote to /tmp outside the workspace",
    }});
    try testing.expect(!under_test.isConfirmed("isolation.mount-namespace"));

    var usable: std.ArrayList([]const u8) = .empty;
    defer usable.deinit(gpa);
    try under_test.usableCapabilities(&usable);
    try testing.expectEqual(@as(usize, 0), usable.items.len);
}

test "diagnostic/spawn smoke" {
    const gpa = testing.allocator;
    const io = std.testing.io;
    var environment = std.process.Environ.Map.init(gpa);
    defer environment.deinit();
    try environment.put("PATH", "/usr/bin:/bin");
    const argv = [_][]const u8{ "/bin/echo", "spawn-smoke" };
    var child = std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = "/bin/echo" } },
        .argv = &argv,
        .environ_map = &environment,
        .cwd = .{ .dir = std.Io.Dir.cwd() },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        std.debug.print("smoke: spawn failed: {s}\n", .{@errorName(err)});
        return err;
    };
    var stdout_file = child.stdout orelse return error.DiagnosticPipeUnavailable;
    child.stdout = null;
    defer stdout_file.close(io);
    var buffer: [128]u8 = undefined;
    var reader = stdout_file.reader(io, &buffer);
    const text = reader.interface.takeDelimiterInclusive('\n') catch "no output\n";
    std.debug.print("smoke: child said: {s}", .{text});
    std.debug.print("harness: waiting for the worker to exit\n", .{});
    const term = try child.wait(io);
    std.debug.print("harness: worker exited\n", .{});
    try testing.expect(term.success());
}
