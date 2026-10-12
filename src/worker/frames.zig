//! Worker/backend frame protocol (M08 groundwork; the shape M13 will freeze for
//! external plugins).
//!
//! One UTF-8 JSON document per line, capped at 1 MiB before parsing, so a
//! hostile or broken peer cannot make the host allocate without bound. A request
//! carries a unique identifier and a method; a response carries exactly one
//! result or one error; events carry a monotonic sequence number within their
//! action stream, so a gap or a regression is detectable instead of being
//! silently reordered. Diagnostics never travel in-band.
//!
//! Encoding builds its document in a short-lived arena and returns bytes owned
//! by the caller; decoding borrows from the line it is given, except for the
//! handshake capability list, which it copies.
const std = @import("std");
const canonical = @import("../core/canonical.zig");

pub const max_frame_bytes = 1024 * 1024;

pub const Error = error{
    FrameTooLarge,
    InvalidFrame,
    UnsupportedProtocol,
    DuplicateRequestId,
    UnknownRequestId,
    NonMonotonicSequence,
    OutOfMemory,
};

pub const protocol_major = 1;
pub const protocol_minor = 0;

pub const Handshake = struct {
    major: u32 = protocol_major,
    minor: u32 = protocol_minor,
    capabilities: []const []const u8 = &.{},
    /// Session identity the peer presents. Authentication decides whether it is
    /// accepted; the claim itself is never trust.
    session: []const u8 = "",
};

pub const Request = struct {
    id: u64,
    method: []const u8,
    /// Method parameters as canonical JSON text (empty when absent).
    parameters: []const u8 = "",
};

pub const Response = struct {
    id: u64,
    /// Exactly one of these is set.
    result: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const Event = struct {
    action: u64,
    sequence: u64,
    kind: []const u8,
    payload: []const u8 = "",
};

pub const Frame = union(enum) {
    handshake: Handshake,
    request: Request,
    response: Response,
    event: Event,

    /// Releases everything `decode` copied. A frame built by the caller holds
    /// borrowed strings and must not be passed here.
    pub fn deinit(self: Frame, gpa: std.mem.Allocator) void {
        switch (self) {
            .handshake => |handshake| {
                for (handshake.capabilities) |capability| gpa.free(capability);
                gpa.free(handshake.capabilities);
                gpa.free(handshake.session);
            },
            .request => |request| {
                gpa.free(request.method);
                if (request.parameters.len > 0) gpa.free(request.parameters);
            },
            .response => |response| {
                if (response.result) |text| gpa.free(text);
                if (response.error_code) |text| gpa.free(text);
                if (response.error_message) |text| gpa.free(text);
            },
            .event => |event| {
                gpa.free(event.kind);
                if (event.payload.len > 0) gpa.free(event.payload);
            },
        }
    }
};

fn stringValue(arena: std.mem.Allocator, text: []const u8) canonical.Value {
    return .{ .string = arena.dupe(u8, text) catch unreachable };
}

fn parsedValue(arena: std.mem.Allocator, text: []const u8) Error!canonical.Value {
    if (text.len == 0) return .null;
    var diagnostic: canonical.Diagnostic = .{};
    return canonical.parse(arena, text, &diagnostic) catch error.InvalidFrame;
}

/// Encodes a frame as one line (the caller appends the newline).
pub fn encodeAlloc(gpa: std.mem.Allocator, frame: Frame) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var document: canonical.Value = switch (frame) {
        .handshake => |handshake| blk: {
            const capabilities = try arena.alloc(canonical.Value, handshake.capabilities.len);
            for (handshake.capabilities, 0..) |capability, index| {
                capabilities[index] = stringValue(arena, capability);
            }
            const protocol = try arena.alloc(canonical.Entry, 2);
            protocol[0] = .{ .key = try arena.dupe(u8, "major"), .value = .{ .integer = @intCast(handshake.major) } };
            protocol[1] = .{ .key = try arena.dupe(u8, "minor"), .value = .{ .integer = @intCast(handshake.minor) } };
            const fields = try arena.alloc(canonical.Entry, 4);
            fields[0] = .{ .key = try arena.dupe(u8, "capabilities"), .value = .{ .array = capabilities } };
            fields[1] = .{ .key = try arena.dupe(u8, "kind"), .value = stringValue(arena, "handshake") };
            fields[2] = .{ .key = try arena.dupe(u8, "protocol"), .value = .{ .object = protocol } };
            fields[3] = .{ .key = try arena.dupe(u8, "session"), .value = stringValue(arena, handshake.session) };
            break :blk .{ .object = fields };
        },
        .request => |request| blk: {
            var fields: std.ArrayList(canonical.Entry) = .empty;
            try fields.append(arena, .{ .key = try arena.dupe(u8, "id"), .value = .{ .integer = @intCast(request.id) } });
            try fields.append(arena, .{ .key = try arena.dupe(u8, "kind"), .value = stringValue(arena, "request") });
            try fields.append(arena, .{ .key = try arena.dupe(u8, "method"), .value = stringValue(arena, request.method) });
            if (request.parameters.len > 0) {
                try fields.append(arena, .{ .key = try arena.dupe(u8, "params"), .value = try parsedValue(arena, request.parameters) });
            }
            break :blk .{ .object = try fields.toOwnedSlice(arena) };
        },
        .response => |response| blk: {
            if ((response.result == null) == (response.error_code == null)) return error.InvalidFrame;
            var fields: std.ArrayList(canonical.Entry) = .empty;
            try fields.append(arena, .{ .key = try arena.dupe(u8, "id"), .value = .{ .integer = @intCast(response.id) } });
            try fields.append(arena, .{ .key = try arena.dupe(u8, "kind"), .value = stringValue(arena, "response") });
            if (response.result) |text| {
                try fields.append(arena, .{ .key = try arena.dupe(u8, "result"), .value = try parsedValue(arena, text) });
            } else {
                const error_fields = try arena.alloc(canonical.Entry, 2);
                error_fields[0] = .{ .key = try arena.dupe(u8, "code"), .value = stringValue(arena, response.error_code.?) };
                error_fields[1] = .{ .key = try arena.dupe(u8, "message"), .value = stringValue(arena, response.error_message orelse "") };
                try fields.append(arena, .{ .key = try arena.dupe(u8, "error"), .value = .{ .object = error_fields } });
            }
            break :blk .{ .object = try fields.toOwnedSlice(arena) };
        },
        .event => |event| blk: {
            var fields: std.ArrayList(canonical.Entry) = .empty;
            try fields.append(arena, .{ .key = try arena.dupe(u8, "action"), .value = .{ .integer = @intCast(event.action) } });
            try fields.append(arena, .{ .key = try arena.dupe(u8, "kind"), .value = stringValue(arena, "event") });
            try fields.append(arena, .{ .key = try arena.dupe(u8, "name"), .value = stringValue(arena, event.kind) });
            if (event.payload.len > 0) {
                try fields.append(arena, .{ .key = try arena.dupe(u8, "payload"), .value = try parsedValue(arena, event.payload) });
            }
            try fields.append(arena, .{ .key = try arena.dupe(u8, "sequence"), .value = .{ .integer = @intCast(event.sequence) } });
            break :blk .{ .object = try fields.toOwnedSlice(arena) };
        },
    };

    canonical.canonicalize(&document);
    const encoded = try canonical.encodeAlloc(gpa, document);
    if (encoded.len > max_frame_bytes) {
        gpa.free(encoded);
        return error.FrameTooLarge;
    }
    return encoded;
}

/// Decodes one line (without its newline). Every string in the returned frame
/// is copied and owned by the caller; release them with `Frame.deinit`.
pub fn decode(gpa: std.mem.Allocator, line: []const u8) Error!Frame {
    if (line.len == 0) return error.InvalidFrame;
    if (line.len > max_frame_bytes) return error.FrameTooLarge;

    var diagnostic: canonical.Diagnostic = .{};
    const document = canonical.parse(gpa, line, &diagnostic) catch return error.InvalidFrame;
    defer document.deinit(gpa);

    const object = switch (document) {
        .object => |entries| entries,
        else => return error.InvalidFrame,
    };

    const kind = stringField(object, "kind") orelse return error.InvalidFrame;
    if (std.mem.eql(u8, kind, "handshake")) {
        const protocol_value = objectField(object, "protocol") orelse return error.InvalidFrame;
        const protocol = switch (protocol_value) {
            .object => |entries| entries,
            else => return error.InvalidFrame,
        };
        const major = integerField(protocol, "major") orelse return error.InvalidFrame;
        if (major != protocol_major) return error.UnsupportedProtocol;
        const minor = integerField(protocol, "minor") orelse return error.InvalidFrame;

        const items: []const canonical.Value = if (objectField(object, "capabilities")) |list_value| switch (list_value) {
            .array => |values| values,
            else => return error.InvalidFrame,
        } else &.{};
        const capabilities = try gpa.alloc([]const u8, items.len);
        errdefer gpa.free(capabilities);
        for (items, 0..) |item, index| {
            capabilities[index] = switch (item) {
                .string => |text| try gpa.dupe(u8, text),
                else => {
                    for (capabilities[0..index]) |capability| gpa.free(capability);
                    gpa.free(capabilities);
                    return error.InvalidFrame;
                },
            };
        }
        const session = try gpa.dupe(u8, stringField(object, "session") orelse return error.InvalidFrame);
        return .{ .handshake = .{
            .major = @intCast(major),
            .minor = @intCast(minor),
            .capabilities = capabilities,
            .session = session,
        } };
    }
    if (std.mem.eql(u8, kind, "request")) {
        const method = try gpa.dupe(u8, stringField(object, "method") orelse return error.InvalidFrame);
        errdefer gpa.free(method);
        var parameters: []const u8 = "";
        if (objectField(object, "params")) |params_value| {
            parameters = try canonical.encodeAlloc(gpa, params_value);
        }
        return .{ .request = .{
            .id = @intCast(integerField(object, "id") orelse return error.InvalidFrame),
            .method = method,
            .parameters = parameters,
        } };
    }
    if (std.mem.eql(u8, kind, "response")) {
        const result_present = objectField(object, "result");
        const error_present = objectField(object, "error");
        if ((result_present == null) == (error_present == null)) return error.InvalidFrame;
        var result: ?[]const u8 = null;
        if (result_present) |value| result = try canonical.encodeAlloc(gpa, value);
        errdefer if (result) |text| gpa.free(text);
        var error_code: ?[]const u8 = null;
        var error_message: ?[]const u8 = null;
        if (error_present) |value| {
            const entries = switch (value) {
                .object => |list| list,
                else => return error.InvalidFrame,
            };
            error_code = try gpa.dupe(u8, stringField(entries, "code") orelse return error.InvalidFrame);
            error_message = try gpa.dupe(u8, stringField(entries, "message") orelse return error.InvalidFrame);
        }
        return .{ .response = .{
            .id = @intCast(integerField(object, "id") orelse return error.InvalidFrame),
            .result = result,
            .error_code = error_code,
            .error_message = error_message,
        } };
    }
    if (std.mem.eql(u8, kind, "event")) {
        const name = try gpa.dupe(u8, stringField(object, "name") orelse return error.InvalidFrame);
        errdefer gpa.free(name);
        var payload: []const u8 = "";
        if (objectField(object, "payload")) |payload_value| {
            payload = try canonical.encodeAlloc(gpa, payload_value);
        }
        return .{ .event = .{
            .action = @intCast(integerField(object, "action") orelse return error.InvalidFrame),
            .sequence = @intCast(integerField(object, "sequence") orelse return error.InvalidFrame),
            .kind = name,
            .payload = payload,
        } };
    }
    return error.InvalidFrame;
}

fn objectField(entries: []const canonical.Entry, key: []const u8) ?canonical.Value {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn stringField(entries: []const canonical.Entry, key: []const u8) ?[]const u8 {
    const value = objectField(entries, key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn integerField(entries: []const canonical.Entry, key: []const u8) ?i64 {
    const value = objectField(entries, key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

/// Per-session protocol state: request identifier uniqueness and event sequence
/// monotonicity. A peer cannot replay an identifier or reorder a stream without
/// being detected.
pub const Session = struct {
    open_requests: std.ArrayList(u64) = .empty,
    action_sequences: std.ArrayList(SequenceEntry) = .empty,
    gpa: std.mem.Allocator,

    pub const SequenceEntry = struct {
        action: u64,
        highest: u64,
    };

    pub fn init(gpa: std.mem.Allocator) Session {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Session) void {
        self.open_requests.deinit(self.gpa);
        self.action_sequences.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn acceptRequest(self: *Session, id: u64) Error!void {
        for (self.open_requests.items) |open_id| {
            if (open_id == id) return error.DuplicateRequestId;
        }
        try self.open_requests.append(self.gpa, id);
    }

    pub fn acceptResponse(self: *Session, id: u64) Error!void {
        for (self.open_requests.items, 0..) |open_id, index| {
            if (open_id == id) {
                _ = self.open_requests.swapRemove(index);
                return;
            }
        }
        return error.UnknownRequestId;
    }

    pub fn acceptEvent(self: *Session, action: u64, sequence: u64) Error!void {
        for (self.action_sequences.items) |*entry| {
            if (entry.action == action) {
                if (sequence <= entry.highest) return error.NonMonotonicSequence;
                entry.highest = sequence;
                return;
            }
        }
        try self.action_sequences.append(self.gpa, .{ .action = action, .highest = sequence });
    }

    pub fn openRequestCount(self: Session) usize {
        return self.open_requests.items.len;
    }
};

test "m08/frame protocol bounds, identity and ordering" {
    const gpa = std.testing.allocator;

    const request_line = try encodeAlloc(gpa, .{ .request = .{ .id = 7, .method = "execute", .parameters = "{\"a\":1}" } });
    defer gpa.free(request_line);
    try std.testing.expect(request_line.len <= max_frame_bytes);
    const decoded = try decode(gpa, request_line);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 7), decoded.request.id);
    try std.testing.expectEqualStrings("execute", decoded.request.method);

    // A handshake round trip copies its capability list and can be freed.
    const handshake_line = try encodeAlloc(gpa, .{ .handshake = .{ .capabilities = &.{ "isolation.user-namespace", "artifacts.transfer" }, .session = "s-1" } });
    defer gpa.free(handshake_line);
    const handshake = try decode(gpa, handshake_line);
    defer handshake.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), handshake.handshake.capabilities.len);
    try std.testing.expectEqualStrings("s-1", handshake.handshake.session);

    // A frame beyond the limit is refused before parsing.
    const oversize = try gpa.alloc(u8, max_frame_bytes + 1);
    defer gpa.free(oversize);
    @memset(oversize, 'x');
    try std.testing.expectError(error.FrameTooLarge, decode(gpa, oversize));

    // Malformed, unknown-kind and version-mismatched frames are refused.
    try std.testing.expectError(error.InvalidFrame, decode(gpa, "not json"));
    try std.testing.expectError(error.InvalidFrame, decode(gpa, "{\"kind\":\"nonsense\"}"));
    try std.testing.expectError(error.InvalidFrame, decode(gpa, ""));
    try std.testing.expectError(
        error.UnsupportedProtocol,
        decode(gpa, "{\"capabilities\":[],\"kind\":\"handshake\",\"protocol\":{\"major\":2,\"minor\":0},\"session\":\"s\"}"),
    );

    // A response carries exactly one result or one error.
    try std.testing.expectError(error.InvalidFrame, decode(gpa, "{\"id\":1,\"kind\":\"response\"}"));
    const error_line = try encodeAlloc(gpa, .{ .response = .{ .id = 9, .error_code = "POLICY", .error_message = "denied" } });
    defer gpa.free(error_line);
    const decoded_error = try decode(gpa, error_line);
    defer decoded_error.deinit(gpa);
    try std.testing.expectEqualStrings("POLICY", decoded_error.response.error_code.?);

    // Session state: duplicate identifiers, unknown identifiers and reordered
    // event streams are all detected.
    var session = Session.init(gpa);
    defer session.deinit();
    try session.acceptRequest(1);
    try std.testing.expectError(error.DuplicateRequestId, session.acceptRequest(1));
    try std.testing.expectError(error.UnknownRequestId, session.acceptResponse(2));
    try session.acceptResponse(1);
    try std.testing.expectEqual(@as(usize, 0), session.openRequestCount());

    try session.acceptEvent(42, 1);
    try session.acceptEvent(42, 2);
    try std.testing.expectError(error.NonMonotonicSequence, session.acceptEvent(42, 2));
    try std.testing.expectError(error.NonMonotonicSequence, session.acceptEvent(42, 1));
    try session.acceptEvent(43, 1);
}
