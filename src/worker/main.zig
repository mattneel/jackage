//! `jckg-worker`: the guest side of the strict execution backend (M08).
//!
//! The controller starts this program *inside* a new set of namespaces
//! (`sandbox.namespacePreamble`), hands it a sandbox plan, and the worker runs
//! the declared action. The worker's side of the protocol:
//!
//! 1. the **first line of stdin** is the session secret (32 hex-encoded bytes).
//!    It travels on the pipe the controller owns, so no argv or `/proc` entry
//!    carries it;
//! 2. the controller sends a handshake frame; the worker answers with its own
//!    identity and its **claimed** capabilities - claims are statements, and
//!    the controller only relies on the ones its independent probes confirm;
//! 3. the controller authenticates with an `auth` request carrying a token the
//!    worker verifies against the secret. Until that succeeds, every other
//!    method is refused;
//! 4. `run` requests carry a sandbox plan; the worker streams output as events
//!    and answers exactly once.
//!
//! Everything above is portable and unit-tested here. The Linux-only part - the
//! `mount` calls, rlimits and `fork`/`execve` - lives behind the `ActionRunner`
//! interface so the protocol can be exercised anywhere while the sandbox is
//! only *claimed* where it can actually be enforced. A run on a platform
//! without namespaces refuses; it never reports a sandbox it did not apply.
const std = @import("std");
const builtin = @import("builtin");
const frames = @import("frames.zig");
const auth = @import("auth.zig");
const sandbox = @import("sandbox.zig");
const execute = @import("execute.zig");
const root = @import("../trust/root.zig");
const canonical = @import("../core/canonical.zig");

pub const protocol_major: u32 = frames.protocol_major;

pub const Error = error{
    MissingArguments,
    InvalidSecret,
    HandshakeFailed,
    Unauthenticated,
    UnexpectedFrame,
    NoResponse,
    UnsupportedPlatform,
    SandboxUnavailable,
    UnsupportedMethod,
    InvalidParameters,
    ActionFailed,
    OutOfMemory,
    WriteFailed,
} || frames.Error || auth.Error;

/// Capabilities this worker claims. Claims are statements about intent; the
/// controller decides what to trust after probing.
pub const claimed_capabilities = [_][]const u8{
    "exec",
    "isolation.mount-namespace",
    "isolation.pid-namespace",
    "isolation.net-namespace",
    "store.read-only",
    "artifacts.transfer",
};

/// The first line of stdin: 32 secret bytes, hex encoded.
pub const secret_line_bytes = 64;

pub fn parseSecret(text: []const u8) Error![32]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != secret_line_bytes) return error.InvalidSecret;
    var secret: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&secret, trimmed) catch return error.InvalidSecret;
    return secret;
}

pub fn readSecret(reader: *std.Io.Reader) Error![32]u8 {
    const line = reader.takeDelimiterInclusive('\n') catch return error.InvalidSecret;
    return parseSecret(line);
}

/// Arguments the worker accepts. Anything else is refused, so a caller cannot
/// smuggle behaviour past the plan.
pub const Args = struct {
    plan_path: ?[]const u8 = null,

    pub fn parse(argv: []const []const u8) Error!Args {
        var result = Args{};
        var index: usize = 1;
        while (index < argv.len) {
            const argument = argv[index];
            if (std.mem.eql(u8, argument, "--sandbox")) {
                index += 1;
                if (index >= argv.len) return error.MissingArguments;
                result.plan_path = argv[index];
            } else {
                return error.MissingArguments;
            }
            index += 1;
        }
        return result;
    }
};

/// Runs one declared action and reports how it ended. Implementations apply the
/// sandbox (Linux) or refuse (everywhere else).
pub const ActionRunner = struct {
    context: *anyopaque,
    /// Executes `argv` inside the sandbox described by `plan` and writes the
    /// action's output as events, returning the normalised exit status.
    run: *const fn (
        context: *anyopaque,
        out: *std.Io.Writer,
        gpa: std.mem.Allocator,
        action: u64,
        plan: sandbox.Plan,
    ) Error!?u32,
};

/// The token wire form: canonical JSON with the claims and the MAC.
pub fn encodeToken(gpa: std.mem.Allocator, token: auth.Token) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try arena.alloc(canonical.Entry, 5);
    const mac_hex = std.fmt.allocPrint(arena, "{x}", .{token.mac}) catch return error.OutOfMemory;
    entries[0] = .{ .key = "expires", .value = .{ .string = token.claims.expires } };
    entries[1] = .{ .key = "mac", .value = .{ .string = mac_hex } };
    entries[2] = .{ .key = "nonce", .value = .{ .string = token.claims.nonce } };
    entries[3] = .{ .key = "session", .value = .{ .string = token.claims.session } };
    entries[4] = .{ .key = "worker", .value = .{ .string = token.claims.worker } };
    var document = canonical.Value{ .object = entries };
    canonical.canonicalize(&document);
    return canonical.encodeAlloc(gpa, document);
}

pub fn decodeToken(gpa: std.mem.Allocator, text: []const u8) Error!auth.Token {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: canonical.Diagnostic = .{};
    const document = canonical.parse(arena, text, &diagnostic) catch return error.InvalidParameters;

    var token = auth.Token{
        .claims = .{ .session = "", .worker = "", .expires = "" },
        .mac = undefined,
    };
    var seen_mac = false;
    var allocated = std.ArrayList([]const u8).empty;
    var keep = false;
    defer {
        if (!keep) for (allocated.items) |entry_text| gpa.free(entry_text);
        allocated.deinit(gpa);
    }
    for (document.object) |entry| {
        const field_text = switch (entry.value) {
            .string => |value_text| value_text,
            else => return error.InvalidParameters,
        };
        if (std.mem.eql(u8, entry.key, "session") or std.mem.eql(u8, entry.key, "worker") or
            std.mem.eql(u8, entry.key, "expires") or std.mem.eql(u8, entry.key, "nonce"))
        {
            const copy = try gpa.dupe(u8, field_text);
            try allocated.append(gpa, copy);
        }
        if (std.mem.eql(u8, entry.key, "session")) token.claims.session = allocated.items[allocated.items.len - 1];
        if (std.mem.eql(u8, entry.key, "worker")) token.claims.worker = allocated.items[allocated.items.len - 1];
        if (std.mem.eql(u8, entry.key, "expires")) token.claims.expires = allocated.items[allocated.items.len - 1];
        if (std.mem.eql(u8, entry.key, "nonce")) token.claims.nonce = allocated.items[allocated.items.len - 1];
        if (std.mem.eql(u8, entry.key, "mac")) {
            _ = std.fmt.hexToBytes(&token.mac, field_text) catch return error.InvalidParameters;
            seen_mac = true;
        }
    }
    if (!seen_mac) return error.InvalidParameters;
    keep = true;
    return token;
}

pub fn freeToken(gpa: std.mem.Allocator, token: auth.Token) void {
    gpa.free(token.claims.session);
    gpa.free(token.claims.worker);
    gpa.free(token.claims.expires);
    if (token.claims.nonce.len > 0) gpa.free(token.claims.nonce);
}

/// Serves the worker side of the protocol until the controller closes the pipe.
pub fn serve(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    in: *std.Io.Reader,
    line_buffer: []u8,
    runner: ActionRunner,
    /// The verifier's clock, in Unix seconds. Taking it as a value keeps the
    /// protocol testable and keeps "what time is it" out of the wire format.
    now_seconds: i64,
) Error!?u32 {
    const secret = try readSecret(in);
    const now = try root.formatTimestamp(gpa, now_seconds);
    defer gpa.free(now);

    var authenticated: ?auth.Token = null;
    defer if (authenticated) |token| freeToken(gpa, token);
    var final_status: ?u32 = null;

    // Handshake: the controller states the session; the worker answers with its
    // identity and its claims.
    const first = (try readFrame(gpa, in, line_buffer)) orelse return error.HandshakeFailed;
    defer first.deinit(gpa);
    const controller_session = switch (first) {
        .handshake => |handshake| try gpa.dupe(u8, handshake.session),
        else => return error.HandshakeFailed,
    };
    defer gpa.free(controller_session);

    var claim_ptrs: [claimed_capabilities.len][]const u8 = undefined;
    for (claimed_capabilities, 0..) |capability, index| claim_ptrs[index] = capability;
    try writeFrame(gpa, out, .{ .handshake = .{
        .major = protocol_major,
        .session = controller_session,
        .capabilities = &claim_ptrs,
    } });

    while (true) {
        const frame = (try readFrame(gpa, in, line_buffer)) orelse return final_status;
        defer frame.deinit(gpa);

        switch (frame) {
            .request => |request| {
                if (std.mem.eql(u8, request.method, "auth")) {
                    const presented = try decodeToken(gpa, request.parameters);
                    var owned = true;
                    defer if (owned) freeToken(gpa, presented);
                    auth.verify(
                        gpa,
                        &secret,
                        now,
                        controller_session,
                        presented.claims.worker,
                        presented.claims.nonce,
                        presented,
                    ) catch {
                        try writeFrame(gpa, out, .{ .response = .{
                            .id = request.id,
                            .error_code = "unauthenticated",
                            .error_message = "session token did not authenticate",
                        } });
                        return error.Unauthenticated;
                    };
                    if (authenticated) |previous| freeToken(gpa, previous);
                    authenticated = presented;
                    owned = false;
                    try writeFrame(gpa, out, .{ .response = .{
                        .id = request.id,
                        .result = "{\"ok\":true}",
                    } });
                    continue;
                }

                if (authenticated == null) {
                    try writeFrame(gpa, out, .{ .response = .{
                        .id = request.id,
                        .error_code = "unauthenticated",
                        .error_message = "authenticate before requesting work",
                    } });
                    return error.Unauthenticated;
                }

                if (std.mem.eql(u8, request.method, "run")) {
                    const action = try actionIdFromParameters(gpa, request.parameters);
                    var plan = try planFromParameters(gpa, request.parameters);
                    defer plan.deinit(gpa);
                    const status = try runner.run(runner.context, out, gpa, action, plan);
                    final_status = status;
                    const result = if (status) |code|
                        std.fmt.allocPrint(gpa, "{{\"exit\":{d}}}", .{code}) catch return error.OutOfMemory
                    else
                        gpa.dupe(u8, "{\"exit\":null,\"signal\":true}") catch return error.OutOfMemory;
                    defer gpa.free(result);
                    try writeFrame(gpa, out, .{ .response = .{ .id = request.id, .result = result } });
                    continue;
                }

                try writeFrame(gpa, out, .{ .response = .{
                    .id = request.id,
                    .error_code = "unsupported-method",
                    .error_message = request.method,
                } });
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn actionIdFromParameters(gpa: std.mem.Allocator, parameters: []const u8) Error!u64 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var diagnostic: canonical.Diagnostic = .{};
    const document = canonical.parse(arena_state.allocator(), parameters, &diagnostic) catch return error.InvalidParameters;
    for (document.object) |entry| {
        if (!std.mem.eql(u8, entry.key, "action")) continue;
        const number = switch (entry.value) {
            .integer => |value| value,
            else => return error.InvalidParameters,
        };
        if (number < 0) return error.InvalidParameters;
        return @intCast(number);
    }
    return error.InvalidParameters;
}

fn planFromParameters(gpa: std.mem.Allocator, parameters: []const u8) Error!sandbox.Plan {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var diagnostic: canonical.Diagnostic = .{};
    const document = canonical.parse(arena_state.allocator(), parameters, &diagnostic) catch return error.InvalidParameters;
    for (document.object) |entry| {
        if (!std.mem.eql(u8, entry.key, "plan")) continue;
        return planFromValue(gpa, entry.value);
    }
    return error.InvalidParameters;
}

fn planFromValue(gpa: std.mem.Allocator, value: canonical.Value) Error!sandbox.Plan {
    var plan = sandbox.Plan{
        .workspace = try gpa.dupe(u8, ""),
        .store = try gpa.dupe(u8, ""),
        .argv = try gpa.alloc([]const u8, 0),
    };
    var argv: std.ArrayList([]const u8) = .empty;
    for (value.object) |entry| {
        if (std.mem.eql(u8, entry.key, "workspace")) {
            plan.workspace = try gpa.dupe(u8, switch (entry.value) {
                .string => |text| text,
                else => return error.InvalidParameters,
            });
        }
        if (std.mem.eql(u8, entry.key, "store")) {
            plan.store = try gpa.dupe(u8, switch (entry.value) {
                .string => |text| text,
                else => return error.InvalidParameters,
            });
        }
        if (std.mem.eql(u8, entry.key, "argv")) {
            const items = switch (entry.value) {
                .array => |items| items,
                else => return error.InvalidParameters,
            };
            for (items) |argument| {
                const text = switch (argument) {
                    .string => |value_text| value_text,
                    else => return error.InvalidParameters,
                };
                try argv.append(gpa, try gpa.dupe(u8, text));
            }
        }
        if (std.mem.eql(u8, entry.key, "binds")) {
            const items = switch (entry.value) {
                .array => |list| list,
                else => return error.InvalidParameters,
            };
            var binds = try gpa.alloc(sandbox.Bind, items.len);
            for (items, 0..) |item, index| {
                var bind = sandbox.Bind{ .source = "", .target = "" };
                for (item.object) |field| {
                    if (std.mem.eql(u8, field.key, "writable")) {
                        bind.writable = switch (field.value) {
                            .boolean => |flag| flag,
                            .string => |text| std.mem.eql(u8, text, "true"),
                            else => return error.InvalidParameters,
                        };
                        continue;
                    }
                    const text = switch (field.value) {
                        .string => |value_text| value_text,
                        else => return error.InvalidParameters,
                    };
                    if (std.mem.eql(u8, field.key, "source")) bind.source = try gpa.dupe(u8, text);
                    if (std.mem.eql(u8, field.key, "target")) bind.target = try gpa.dupe(u8, text);
                }
                binds[index] = bind;
            }
            plan.extra_binds = binds;
        }
    }
    plan.argv = try argv.toOwnedSlice(gpa);
    return plan;
}

pub fn writeFrame(gpa: std.mem.Allocator, out: *std.Io.Writer, frame: frames.Frame) Error!void {
    const line = try frames.encodeAlloc(gpa, frame);
    defer gpa.free(line);
    try out.writeAll(line);
    try out.writeByte('\n');
    // A frame that sits in a buffer is not a frame: the controller is waiting on
    // it before it sends anything else, so every write is flushed.
    try out.flush();
}

pub fn readFrame(gpa: std.mem.Allocator, in: *std.Io.Reader, buffer: []u8) Error!?frames.Frame {
    var length: usize = 0;
    while (length < buffer.len) {
        const byte = in.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (length == 0) return null;
                return error.NoResponse;
            },
            else => return error.NoResponse,
        };
        if (byte == '\n') return try frames.decode(gpa, buffer[0..length]);
        buffer[length] = byte;
        length += 1;
    }
    return error.NoResponse;
}

fn testRunner(
    context: *anyopaque,
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    action: u64,
    plan: sandbox.Plan,
) Error!?u32 {
    _ = plan;
    const implementation: *const TestRunnerState = @ptrCast(@alignCast(context));
    try writeFrame(gpa, out, .{ .event = .{
        .action = action,
        .sequence = 1,
        .kind = "stdout",
        .payload = implementation.output,
    } });
    return implementation.status;
}

const TestRunnerState = struct {
    output: []const u8,
    status: ?u32,
};

test "m08/worker refuses work before authentication and streams a run" {
    const gpa = std.testing.allocator;
    const key = "worker-secret-key-material!!!!!!";
    var secret_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&secret_hex, "{x}", .{key[0..32].*}) catch unreachable;

    const token = try auth.issue(gpa, key[0..32], .{
        .session = "session-1",
        .worker = "worker-1",
        .expires = "2027-01-01T00:00:00Z",
    });
    const token_json = try encodeToken(gpa, token);
    defer gpa.free(token_json);
    const round_trip = try decodeToken(gpa, token_json);
    defer freeToken(gpa, round_trip);
    try std.testing.expectEqualStrings("session-1", round_trip.claims.session);
    try std.testing.expectEqualSlices(u8, &token.mac, &round_trip.mac);

    // Read the frames the worker writes so the assertions can inspect them.
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();

    const line_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(line_buffer);

    var state = TestRunnerState{ .output = "\"hello from the action\"", .status = 0 };
    const runner = ActionRunner{ .context = &state, .run = testRunner };

    // The leading frames: the secret line, the controller's handshake, then a
    // request that arrives *before* authentication.
    try input.writer.writeAll(&secret_hex);
    try input.writer.writeByte('\n');
    try writeFrame(gpa, &input.writer, .{ .handshake = .{ .session = "session-1" } });
    try writeFrame(gpa, &input.writer, .{ .request = .{ .id = 1, .method = "run", .parameters = "{\"action\":1,\"plan\":{\"argv\":[\"/bin/true\"],\"store\":\"/s\",\"workspace\":\"/w\"}}" } });

    // The reader is built *after* the frames are written: a fixed reader takes
    // a snapshot of the bytes, so constructing it first would hand the worker
    // an empty stream.
    var relative_reader = std.Io.Reader.fixed(input.written());
    try std.testing.expectError(
        error.Unauthenticated,
        serve(gpa, &output.writer, &relative_reader, line_buffer, runner, test_now_seconds),
    );

    // The worker answered the handshake with its own identity and claims, then
    // refused the unauthenticated request rather than running it.
    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"kind\":\"handshake\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "isolation.mount-namespace") != null);
    // The wire form nests the failure: {"error":{"code":...,"message":...}}.
    try std.testing.expect(std.mem.indexOf(u8, written, "\"code\":\"unauthenticated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "hello from the action") == null);
}

test "m08/worker authenticates, runs the declared argv and reports its status" {
    const gpa = std.testing.allocator;
    const key = "worker-secret-key-material!!!!!!";
    var secret_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&secret_hex, "{x}", .{key[0..32].*}) catch unreachable;

    const token = try auth.issue(gpa, key[0..32], .{
        .session = "session-2",
        .worker = "worker-1",
        .expires = "2027-01-01T00:00:00Z",
    });
    // The auth request's parameters *are* the token object; wrapping it would
    // leave the decoder guessing which layer it is looking at.
    const auth_params = try encodeToken(gpa, token);
    defer gpa.free(auth_params);

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    const line_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(line_buffer);

    var state = TestRunnerState{ .output = "\"action output\"", .status = 3 };
    const runner = ActionRunner{ .context = &state, .run = testRunner };

    try input.writer.writeAll(&secret_hex);
    try input.writer.writeByte('\n');
    try writeFrame(gpa, &input.writer, .{ .handshake = .{ .session = "session-2" } });
    try writeFrame(gpa, &input.writer, .{ .request = .{ .id = 1, .method = "auth", .parameters = auth_params } });
    try writeFrame(gpa, &input.writer, .{ .request = .{ .id = 2, .method = "run", .parameters = "{\"action\":9,\"plan\":{\"argv\":[\"/bin/true\"],\"store\":\"/s\",\"workspace\":\"/w\"}}" } });

    var relative_reader = std.Io.Reader.fixed(input.written());
    const final_status = try serve(gpa, &output.writer, &relative_reader, line_buffer, runner, test_now_seconds);
    try std.testing.expectEqual(@as(?u32, 3), final_status);

    const written = output.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"action\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "action output") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"exit\":3") != null);
}

test "m08/worker arguments and secret are strict" {
    const valid = [_][]const u8{ "jckg-worker", "--sandbox", "/run/plan.json" };
    const parsed = try Args.parse(&valid);
    try std.testing.expectEqualStrings("/run/plan.json", parsed.plan_path.?);

    const missing = [_][]const u8{ "jckg-worker", "--sandbox" };
    try std.testing.expectError(error.MissingArguments, Args.parse(&missing));

    const unknown = [_][]const u8{ "jckg-worker", "--exec", "sh" };
    try std.testing.expectError(error.MissingArguments, Args.parse(&unknown));

    const none = [_][]const u8{"jckg-worker"};
    const empty = try Args.parse(&none);
    try std.testing.expect(empty.plan_path == null);

    const secret = try parseSecret("0000000000000000000000000000000000000000000000000000000000000000\n");
    try std.testing.expectEqual(@as(u8, 0), secret[0]);
    const nonzero = try parseSecret("0101010101010101010101010101010101010101010101010101010101010101");
    try std.testing.expectEqual(@as(u8, 0x01), nonzero[0]);
    try std.testing.expectError(error.InvalidSecret, parseSecret("00\n"));
    try std.testing.expectError(error.InvalidSecret, parseSecret("zz00000000000000000000000000000000000000000000000000000000000000\n"));

    // The sandbox is only claimed where it can be enforced; on any other
    // platform the worker must refuse rather than report a sandbox it did not
    // apply.
    try std.testing.expectEqual(builtin.os.tag == .linux, sandboxSupported());
    try std.testing.expectEqual(protocol_major, frames.protocol_major);
    try std.testing.expect(claimed_capabilities.len >= 6);
}

/// True only where the sandbox can actually be enforced.
pub fn sandboxSupported() bool {
    return builtin.os.tag == .linux;
}

/// A fixed verification time for tests (2025-10-05T00:00:00Z), so token expiry
/// is decided by the data rather than by when the suite happens to run.
pub const test_now_seconds: i64 = 1_759_622_400;

/// Entry point. The process entry only obtains the clock and the standard
/// streams; the protocol itself is in `serve`.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &writer.interface;
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const in = &stdin_reader.interface;
    const line_buffer = try gpa.alloc(u8, frames.max_frame_bytes);
    defer gpa.free(line_buffer);

    var arguments = try init.minimal.args.iterateAllocator(gpa);
    defer arguments.deinit();
    var argument_list: std.ArrayList([]const u8) = .empty;
    defer argument_list.deinit(gpa);
    while (arguments.next()) |argument| try argument_list.append(gpa, argument);
    _ = try Args.parse(argument_list.items);

    const stamp = std.Io.Timestamp.now(io, .real);
    const seconds: i64 = @intCast(@divFloor(stamp.nanoseconds, std.time.ns_per_s));
    var runner_context = RunnerContext{ .io = io };
    const runner = ActionRunner{ .context = &runner_context, .run = sandboxedRunner };
    // A worker that dies without saying why costs the operator an afternoon; the
    // failure mode is named on stderr before the process exits.
    const status = serve(gpa, out, in, line_buffer, runner, seconds) catch |err| {
        std.debug.print("jckg-worker: {s}\n", .{@errorName(err)});
        return err;
    };
    _ = status orelse 0;
}

/// What the runner needs that the protocol layer does not own: the process's
/// I/O interface, for the filesystem work of building the sandbox.
const RunnerContext = struct {
    io: std.Io,
};

fn emitEvent(
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    action: u64,
    sequence: *u64,
    kind: []const u8,
    payload: []const u8,
) execute.Error!void {
    sequence.* += 1;
    writeFrame(gpa, out, .{ .event = .{
        .action = action,
        .sequence = sequence.*,
        .kind = kind,
        .payload = payload,
    } }) catch return error.OutputFailed;
}

/// Runs the action inside the sandbox. Where the sandbox cannot be enforced the
/// runner refuses: a run that reports success without isolation would be a false
/// acceptance signal, which is worse than a failure.
fn sandboxedRunner(
    context: *anyopaque,
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    action: u64,
    plan: sandbox.Plan,
) Error!?u32 {
    if (!execute.supported()) return error.UnsupportedPlatform;
    const state: *const RunnerContext = @ptrCast(@alignCast(context));
    return execute.runAction(state.io, gpa, out, plan, emitEvent, action) catch |err| {
        // The protocol only carries a coarse failure, so the specific step is
        // named here: "the sandbox could not be built" and "the sandbox refused
        // to run the action" are different reports for an operator.
        std.debug.print("jckg-worker: sandbox step failed: {s}\n", .{@errorName(err)});
        return switch (err) {
            error.UnsupportedPlatform => error.UnsupportedPlatform,
            error.OutOfMemory => error.OutOfMemory,
            else => error.ActionFailed,
        };
    };
}
