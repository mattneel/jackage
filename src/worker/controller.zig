//! Controller side of the worker protocol (M08).
//!
//! The controller drives a worker process: it performs the handshake, mints and
//! presents a session token, sends requests, reads responses and events, and
//! keeps the session-level invariants (unique request identifiers, monotonic
//! event sequences, exactly one response per request). Capability names a
//! worker claims are only *recorded* here: nothing in this module turns a claim
//! into trust, which is why the reported table has to be confirmed by an
//! independent probe (`CapabilityProbe`) before it is used.
//!
//! The logic is transport-agnostic on purpose: it is written against readers
//! and writers, so the unit tests exercise the real state machine with in-memory
//! streams while the process boundary is exercised in the declared Linux
//! environment.
const std = @import("std");
const auth = @import("auth.zig");
const frames = @import("frames.zig");

pub const Error = error{
    HandshakeFailed,
    WriteFailed,
    UnsupportedProtocol,
    Unauthenticated,
    UnexpectedFrame,
    WorkerError,
    NoResponse,
} || frames.Error;

pub const Claim = struct {
    name: []const u8,
    /// Whether the controller has independently confirmed the claim. A claim
    /// starts unconfirmed and can never be used for a policy decision while it
    /// is.
    confirmed: bool = false,
};

pub const Controller = struct {
    gpa: std.mem.Allocator,
    /// Frames written to the worker.
    out: *std.Io.Writer,
    /// Frames read from the worker.
    in: *std.Io.Reader,
    session: frames.Session,
    /// Session token presented to the worker.
    token: auth.Token,
    next_request_id: u64 = 1,
    /// Capability names the worker claimed, with their confirmation state.
    claims: std.ArrayList(Claim) = .empty,
    /// Handshake data the worker returned.
    worker_session: []const u8 = "",
    /// Scratch buffer for inbound frames; the caller owns it and it must be at
    /// least as large as the largest frame the worker may send.
    line_buffer: []u8,

    pub fn init(
        gpa: std.mem.Allocator,
        out: *std.Io.Writer,
        in: *std.Io.Reader,
        token: auth.Token,
        line_buffer: []u8,
    ) Controller {
        return .{
            .gpa = gpa,
            .out = out,
            .in = in,
            .session = frames.Session.init(gpa),
            .token = token,
            .line_buffer = line_buffer,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.session.deinit();
        for (self.claims.items) |claim| self.gpa.free(claim.name);
        self.claims.deinit(self.gpa);
        // The handshake copies the worker's session identity; it is owned by the
        // controller and must not outlive it.
        if (self.worker_session.len > 0) self.gpa.free(self.worker_session);
        self.* = undefined;
    }

    fn writeFrame(self: *Controller, frame: frames.Frame) Error!void {
        const line = try frames.encodeAlloc(self.gpa, frame);
        defer self.gpa.free(line);
        try self.out.writeAll(line);
        try self.out.writeByte('\n');
    }

    fn readLine(self: *Controller, buffer: []u8) Error!?[]const u8 {
        var length: usize = 0;
        while (length < buffer.len) {
            const byte = self.in.takeByte() catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return error.NoResponse,
            };
            if (byte == '\n') return buffer[0..length];
            buffer[length] = byte;
            length += 1;
        }
        return error.NoResponse;
    }

    fn readFrame(self: *Controller, buffer: []u8) Error!frames.Frame {
        const line = (try self.readLine(buffer)) orelse return error.NoResponse;
        return frames.decode(self.gpa, line);
    }

    /// Performs the handshake and records the worker's claimed capabilities.
    pub fn handshake(self: *Controller, expected_major: u32) Error!void {
        try self.writeFrame(.{ .handshake = .{
            .capabilities = &.{},
            .session = self.token.claims.session,
        } });

        const frame = try self.readFrame(self.line_buffer);
        defer frame.deinit(self.gpa);
        switch (frame) {
            .handshake => |worker_handshake| {
                if (worker_handshake.major != expected_major) return error.UnsupportedProtocol;
                // The worker must present the same session identity it was
                // authenticated for; a mismatch is refused before any work.
                if (!std.mem.eql(u8, worker_handshake.session, self.token.claims.session)) return error.Unauthenticated;
                self.worker_session = try self.gpa.dupe(u8, worker_handshake.session);
                for (worker_handshake.capabilities) |capability| {
                    try self.claims.append(self.gpa, .{ .name = try self.gpa.dupe(u8, capability) });
                }
            },
            else => return error.UnexpectedFrame,
        }
    }

    /// Sends a request and returns the matching response.
    pub fn request(self: *Controller, method: []const u8, parameters: []const u8) Error!frames.Response {
        const id = self.next_request_id;
        self.next_request_id += 1;
        try self.session.acceptRequest(id);
        try self.writeFrame(.{ .request = .{ .id = id, .method = method, .parameters = parameters } });

        const frame = try self.readFrame(self.line_buffer);
        defer frame.deinit(self.gpa);
        switch (frame) {
            .response => |response| {
                if (response.id != id) return error.UnexpectedFrame;
                try self.session.acceptResponse(response.id);
                if (response.error_code != null) return error.WorkerError;
                return response;
            },
            else => return error.UnexpectedFrame,
        }
    }

    /// Records an event, enforcing monotonic sequences per action.
    pub fn acceptEvent(self: *Controller, event: frames.Event) Error!void {
        try self.session.acceptEvent(event.action, event.sequence);
    }

    /// Marks a capability as independently confirmed.
    pub fn confirmClaim(self: *Controller, name: []const u8) Error!void {
        for (self.claims.items) |*claim| {
            if (std.mem.eql(u8, claim.name, name)) {
                claim.confirmed = true;
                return;
            }
        }
        return error.UnexpectedFrame;
    }

    pub fn isConfirmed(self: Controller, name: []const u8) bool {
        for (self.claims.items) |claim| {
            if (std.mem.eql(u8, claim.name, name)) return claim.confirmed;
        }
        return false;
    }

    /// Capabilities a policy may rely on: claimed *and* independently
    /// confirmed. An unconfirmed claim is never returned.
    pub fn usableCapabilities(self: Controller, out: *std.ArrayList([]const u8)) Error!void {
        for (self.claims.items) |claim| {
            if (claim.confirmed) try out.append(self.gpa, claim.name);
        }
    }
};

/// An independent check of a capability claim.
///
/// The probe runs a deliberate violation attempt against the worker and reports
/// whether the claim held. A worker that claims filesystem isolation while the
/// probe can write outside its workspace must be rejected, not trusted: the
/// claim is the thing under test, never the evidence.
pub const CapabilityProbe = struct {
    name: []const u8,
    /// Result of the violation attempt: true when the restriction actually held.
    held: bool,
    detail: []const u8,
};

/// Applies probe results to a controller, confirming or rejecting claims.
pub fn applyProbes(controller: *Controller, probes: []const CapabilityProbe) Error!void {
    for (probes) |probe| {
        if (probe.held) {
            try controller.confirmClaim(probe.name);
            continue;
        }
        // The claim did not hold: remove it entirely so no later policy check
        // can see it as available.
        var index: usize = 0;
        while (index < controller.claims.items.len) {
            if (std.mem.eql(u8, controller.claims.items[index].name, probe.name)) {
                const removed = controller.claims.orderedRemove(index);
                controller.gpa.free(removed.name);
                continue;
            }
            index += 1;
        }
    }
}

const testing = std.testing;

test "m08/STRICT-010 reject fake capabilities: a disproved claim is withdrawn" {
    std.debug.print("JCKG_EVIDENCE STRICT-010\n", .{});
    const gpa = testing.allocator;

    const key = "controller-test-key";
    const token = try auth.issue(gpa, key, .{
        .session = "session-1",
        .worker = "worker-1",
        .expires = "2027-01-01T00:00:00Z",
    });

    // Worker side: what the worker would write, and what it must receive.
    var worker_out: std.Io.Writer.Allocating = .init(gpa);
    defer worker_out.deinit();

    const worker_handshake = try frames.encodeAlloc(gpa, .{ .handshake = .{
        .capabilities = &.{ "isolation.mount-namespace", "artifacts.transfer" },
        .session = "session-1",
    } });
    defer gpa.free(worker_handshake);
    const worker_response = try frames.encodeAlloc(gpa, .{ .response = .{ .id = 1, .result = "{\"ok\":true}" } });
    defer gpa.free(worker_response);

    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try input.writer.writeAll(worker_handshake);
    try input.writer.writeByte('\n');
    try input.writer.writeAll(worker_response);
    try input.writer.writeByte('\n');

    var reader = std.Io.Reader.fixed(input.written());
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();

    const frame_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(frame_buffer);
    var controller = Controller.init(gpa, &output.writer, &reader, token, frame_buffer);
    defer controller.deinit();

    try controller.handshake(frames.protocol_major);
    try testing.expectEqualStrings("session-1", controller.worker_session);
    try testing.expectEqual(@as(usize, 2), controller.claims.items.len);
    // A claim is not trust: nothing is usable before a probe confirms it.
    try testing.expect(!controller.isConfirmed("isolation.mount-namespace"));
    var usable: std.ArrayList([]const u8) = .empty;
    defer usable.deinit(gpa);
    try controller.usableCapabilities(&usable);
    try testing.expectEqual(@as(usize, 0), usable.items.len);

    const response = try controller.request("execute", "{\"argv\":[\"echo\",\"hi\"]}");
    try testing.expect(response.result != null);
    try testing.expectEqual(@as(usize, 0), controller.session.openRequestCount());

    // The controller wrote a well-formed request with a unique identifier.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output.written(), "\n"), '\n');
    var request_seen = false;
    while (lines.next()) |line| {
        const frame = try frames.decode(gpa, line);
        defer frame.deinit(gpa);
        switch (frame) {
            .handshake => |handshake| {
                try testing.expectEqualStrings("session-1", handshake.session);
            },
            .request => |request| {
                request_seen = true;
                try testing.expectEqual(@as(u64, 1), request.id);
                try testing.expectEqualStrings("execute", request.method);
                try testing.expectEqualStrings("{\"argv\":[\"echo\",\"hi\"]}", request.parameters);
            },
            else => return error.UnexpectedFrame,
        }
    }
    try testing.expect(request_seen);

    // Probes decide: one claim holds, the other does not and is removed.
    const probes = [_]CapabilityProbe{
        .{ .name = "isolation.mount-namespace", .held = true, .detail = "escape attempt denied" },
        .{ .name = "artifacts.transfer", .held = false, .detail = "probe could write outside the workspace" },
    };
    try applyProbes(&controller, &probes);
    try testing.expect(controller.isConfirmed("isolation.mount-namespace"));
    try testing.expectEqual(@as(usize, 1), controller.claims.items.len);
    usable.clearRetainingCapacity();
    try controller.usableCapabilities(&usable);
    try testing.expectEqual(@as(usize, 1), usable.items.len);
    try testing.expectEqualStrings("isolation.mount-namespace", usable.items[0]);
}

test "worker controller refuses mismatched session and reordered events" {
    const gpa = testing.allocator;
    const key = "controller-test-key-2";
    const token = try auth.issue(gpa, key, .{
        .session = "session-2",
        .worker = "worker-1",
        .expires = "2027-01-01T00:00:00Z",
    });

    // A worker that answers with a different session identity is refused.
    const mismatched = try frames.encodeAlloc(gpa, .{ .handshake = .{ .session = "session-other" } });
    defer gpa.free(mismatched);
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try input.writer.writeAll(mismatched);
    try input.writer.writeByte('\n');
    var reader = std.Io.Reader.fixed(input.written());
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const frame_buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(frame_buffer);
    var controller = Controller.init(gpa, &output.writer, &reader, token, frame_buffer);
    defer controller.deinit();
    try testing.expectError(error.Unauthenticated, controller.handshake(frames.protocol_major));

    // Event ordering: a regression or a repeat is refused, a new action stream
    // is independent.
    const events = [_]frames.Event{
        .{ .action = 5, .sequence = 1, .kind = "started" },
        .{ .action = 5, .sequence = 2, .kind = "output" },
    };
    try controller.acceptEvent(events[0]);
    try controller.acceptEvent(events[1]);
    try testing.expectError(error.NonMonotonicSequence, controller.acceptEvent(.{ .action = 5, .sequence = 2, .kind = "output" }));
    try testing.expectError(error.NonMonotonicSequence, controller.acceptEvent(.{ .action = 5, .sequence = 0, .kind = "output" }));
    try controller.acceptEvent(.{ .action = 6, .sequence = 1, .kind = "started" });
}
