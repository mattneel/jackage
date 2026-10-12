//! Progress an agent can read rather than scrape (M16, FACTORY-002).
//!
//! A long task reports what it is doing. If the report is a terminal transcript, the
//! only way to use it is to match text - and text matching breaks on the first
//! rewording, in a way that looks like "no progress" rather than like a failure. So the
//! interface is a stream of documents with a schema, and this module is the reader:
//! every line is parsed and validated, and what the caller receives is fields rather
//! than a substring somebody hoped would be there.
//!
//! Validation is not decoration here. Sequence numbers must strictly increase, so a
//! consumer can tell a continued stream from a restarted one and an out-of-order line
//! is refused rather than applied twice. Kinds are enumerated, so an unrecognised kind
//! is a schema error instead of being ignored. A line that is not a document is
//! refused, which is exactly what a plain-text transcript is - and refusing it is the
//! difference between reading the interface and scraping it.
//!
//! Failure is an event like any other: it carries a phase and a reason, so the caller
//! learns *what* failed from the same structured fields it learns progress from.
const std = @import("std");

pub const Error = error{
    InvalidEvent,
    UnknownKind,
    OutOfOrder,
    TerminalText,
    OutOfMemory,
};

pub const Kind = enum {
    stage,
    progress,
    failure,
    done,

    fn parse(text: []const u8) Error!Kind {
        inline for (@typeInfo(Kind).@"enum".field_names) |name| {
            if (std.mem.eql(u8, text, name)) return @field(Kind, name);
        }
        return error.UnknownKind;
    }
};

pub const Event = struct {
    seq: u64,
    kind: Kind,
    phase: []const u8,
    /// A human-readable detail. Optional, because a stage boundary needs none - but the
    /// fields around it are what the caller uses, never this.
    detail: ?[]const u8,

    pub fn deinit(self: Event, gpa: std.mem.Allocator) void {
        gpa.free(self.phase);
        if (self.detail) |detail| gpa.free(detail);
    }
};

pub fn parseEvent(gpa: std.mem.Allocator, line: []const u8) Error!Event {
    const trimmed = std.mem.trim(u8, line, " \r\t\n");
    if (trimmed.len == 0) return error.InvalidEvent;
    // A line that does not even claim to be a document is terminal text: prose, a log
    // line, somebody's progress bar. It is refused with its own error so a caller can
    // tell "this interface sends something else" from "this document is malformed",
    // and a line that does open a document is judged as one whatever shape it turns
    // out to have.
    if (trimmed[0] != '{' and trimmed[0] != '[') return error.TerminalText;

    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return error.InvalidEvent;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEvent;
    const object = parsed.value.object;

    const seq_value = object.get("seq") orelse return error.InvalidEvent;
    const kind_value = object.get("kind") orelse return error.InvalidEvent;
    const phase_value = object.get("phase") orelse return error.InvalidEvent;
    if (seq_value != .integer or kind_value != .string or phase_value != .string) return error.InvalidEvent;
    if (seq_value.integer < 0) return error.InvalidEvent;
    if (phase_value.string.len == 0) return error.InvalidEvent;

    var detail: ?[]const u8 = null;
    if (object.get("detail")) |detail_value| {
        if (detail_value != .string) return error.InvalidEvent;
        detail = detail_value.string;
    }
    // A failure without a reason is the case this interface exists to avoid: the
    // agent would learn that something failed and nothing else.
    const kind = try Kind.parse(kind_value.string);
    if (kind == .failure and detail == null) return error.InvalidEvent;

    return .{
        .seq = @intCast(seq_value.integer),
        .kind = kind,
        .phase = try gpa.dupe(u8, phase_value.string),
        .detail = if (detail) |text| try gpa.dupe(u8, text) else null,
    };
}

pub const Stream = struct {
    events: []Event,
    /// The last phase seen, which is what a consumer shows as "where we are".
    phase: []const u8,
    /// The most recent progress detail, when one arrived.
    progress: ?[]const u8,
    /// The failure, if the stream carries one. Both the phase and the reason come from
    /// fields rather than from text.
    failure: ?Event,

    pub fn deinit(self: Stream, gpa: std.mem.Allocator) void {
        for (self.events) |event| event.deinit(gpa);
        gpa.free(self.events);
        gpa.free(self.phase);
        if (self.progress) |progress| gpa.free(progress);
    }

    pub fn ok(self: Stream) bool {
        return self.failure == null;
    }
};

/// Reads a whole stream, validating each event and the sequence as a whole.
pub fn readStream(gpa: std.mem.Allocator, lines: []const []const u8) Error!Stream {
    var events: std.ArrayList(Event) = .empty;
    errdefer {
        for (events.items) |event| event.deinit(gpa);
        events.deinit(gpa);
    }

    var last_seq: u64 = 0;
    var have_seq = false;
    for (lines) |line| {
        const event = try parseEvent(gpa, line);
        errdefer event.deinit(gpa);
        // Strictly increasing: a repeated or backwards sequence number means the
        // stream restarted or the lines were reassembled wrongly, and applying it
        // twice is worse than refusing it.
        if (have_seq and event.seq <= last_seq) return error.OutOfOrder;
        last_seq = event.seq;
        have_seq = true;
        try events.append(gpa, event);
    }
    if (events.items.len == 0) return error.InvalidEvent;

    // The summary is derived from the fields, so "what happened" is read rather than
    // inferred.
    const last = events.items[events.items.len - 1];
    var progress: ?[]const u8 = null;
    var failure: ?Event = null;
    for (events.items) |event| {
        switch (event.kind) {
            .progress => {
                if (event.detail) |detail| {
                    if (progress) |old| gpa.free(old);
                    progress = gpa.dupe(u8, detail) catch return error.OutOfMemory;
                }
            },
            .failure => failure = event,
            else => {},
        }
    }
    return .{
        .events = try events.toOwnedSlice(gpa),
        .phase = try gpa.dupe(u8, last.phase),
        .progress = progress,
        .failure = failure,
    };
}

test "m16/FACTORY-002 expose structured progress: events are schema-valid and never scraped" {
    std.debug.print("JCKG_EVIDENCE FACTORY-002\n", .{});
    const gpa = std.testing.allocator;

    // A long task's stream as the documented interface emits it: a stage, progress,
    // and a failure carrying its own reason.
    const lines = [_][]const u8{
        "{\"seq\":1,\"kind\":\"stage\",\"phase\":\"resolve\"}",
        "{\"seq\":2,\"kind\":\"progress\",\"phase\":\"resolve\",\"detail\":\"7 packages\"}",
        "{\"seq\":3,\"kind\":\"stage\",\"phase\":\"build\"}",
        "{\"seq\":4,\"kind\":\"progress\",\"phase\":\"build\",\"detail\":\"3/7 steps\"}",
        "{\"seq\":5,\"kind\":\"failure\",\"phase\":\"build\",\"detail\":\"compile error: expected ';'\"}",
    };
    const stream = try readStream(gpa, &lines);
    defer stream.deinit(gpa);

    // Everything the caller needs comes from fields: where we are, how far, and why it
    // stopped.
    try std.testing.expectEqual(@as(usize, 5), stream.events.len);
    try std.testing.expectEqualStrings("build", stream.phase);
    try std.testing.expectEqualStrings("3/7 steps", stream.progress.?);
    try std.testing.expect(!stream.ok());
    try std.testing.expectEqualStrings("compile error: expected ';'", stream.failure.?.detail.?);
    try std.testing.expectEqual(Kind.failure, stream.failure.?.kind);
    try std.testing.expectEqual(@as(u64, 5), stream.failure.?.seq);

    // A stream that ends well reports so, and still carries its last phase.
    const good = [_][]const u8{
        "{\"seq\":1,\"kind\":\"stage\",\"phase\":\"install\"}",
        "{\"seq\":2,\"kind\":\"done\",\"phase\":\"install\"}",
    };
    const finished = try readStream(gpa, &good);
    defer finished.deinit(gpa);
    try std.testing.expect(finished.ok());
    try std.testing.expectEqualStrings("install", finished.phase);

    // A terminal transcript is refused as such, which is the difference between
    // reading the interface and scraping it.
    try std.testing.expectError(error.TerminalText, parseEvent(gpa, "Compiling src/main.zig..."));
    try std.testing.expectError(error.TerminalText, readStream(gpa, &.{ "Building...", "Done." }));

    // Schema violations are refused rather than absorbed: a missing field, an
    // unrecognised kind, a failure with no reason, and a negative sequence number.
    try std.testing.expectError(error.InvalidEvent, parseEvent(gpa, "{}"));
    try std.testing.expectError(error.InvalidEvent, parseEvent(gpa, "{\"kind\":\"stage\",\"phase\":\"x\"}"));
    try std.testing.expectError(error.InvalidEvent, parseEvent(gpa, "{\"seq\":1,\"kind\":\"stage\"}"));
    try std.testing.expectError(error.UnknownKind, parseEvent(gpa, "{\"seq\":1,\"kind\":\"whatever\",\"phase\":\"x\"}"));
    try std.testing.expectError(error.InvalidEvent, parseEvent(gpa, "{\"seq\":1,\"kind\":\"failure\",\"phase\":\"x\"}"));
    try std.testing.expectError(error.InvalidEvent, parseEvent(gpa, "{\"seq\":-1,\"kind\":\"stage\",\"phase\":\"x\"}"));
    try std.testing.expectError(error.InvalidEvent, parseEvent(gpa, "{\"seq\":1,\"kind\":\"stage\",\"phase\":\"\"}"));
    // Prose is terminal text rather than a malformed document: the two are different
    // problems and a caller is told which one it has.
    try std.testing.expectError(error.TerminalText, parseEvent(gpa, "not json at all"));
    // A line that starts as a document but is not one is a schema error.
    try std.testing.expectError(error.InvalidEvent, parseEvent(gpa, "{not json}"));
    try std.testing.expectError(error.InvalidEvent, parseEvent(gpa, "[1,2,3]"));

    // Sequence numbers must strictly increase: a repeated one and a backwards one are
    // both refused, because applying an event twice is worse than refusing it.
    try std.testing.expectError(error.OutOfOrder, readStream(gpa, &.{
        "{\"seq\":2,\"kind\":\"stage\",\"phase\":\"a\"}",
        "{\"seq\":2,\"kind\":\"stage\",\"phase\":\"b\"}",
    }));
    try std.testing.expectError(error.OutOfOrder, readStream(gpa, &.{
        "{\"seq\":2,\"kind\":\"stage\",\"phase\":\"a\"}",
        "{\"seq\":1,\"kind\":\"stage\",\"phase\":\"b\"}",
    }));
    // An empty stream is not a stream.
    try std.testing.expectError(error.InvalidEvent, readStream(gpa, &.{}));
}
