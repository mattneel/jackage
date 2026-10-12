//! Keeping diagnostics out of the protocol, and both under limits (M13, PLUGIN-003, PLUGIN-004).
//!
//! A plugin process has two output streams and they mean different things. Stdout is
//! the protocol: framed documents the core parses. Stderr is diagnostics: text for a
//! person, bounded, and never parsed. The failure this module prevents is a plugin
//! that writes a log line to stdout - the core must notice that the protocol stream
//! is contaminated rather than treat the text as an event or, worse, resynchronize on
//! whatever looks like a frame boundary inside a log line.
//!
//! Backpressure is the other half. A plugin can produce output faster than the core
//! reads it, and the two streams have to behave differently when a buffer fills.
//! Protocol frames are never dropped: dropping one desynchronizes the exchange, and a
//! protocol that silently loses a frame is worse than one that stalls. Diagnostics
//! are different - a log line is not worth stalling a build for - so they are dropped
//! once their bounded buffer is full, and the *count* of dropped lines is reported so
//! the loss is visible instead of implied.
//!
//! When the protocol buffer fills, the reader must make progress, so the module
//! reports a defined boundary (`WouldBlock`) rather than growing without limit or
//! discarding. The caller reads, the buffer drains, the plugin resumes: backpressure
//! rather than data loss.
const std = @import("std");

pub const Error = error{
    ProtocolContaminated,
    DiagnosticTooLong,
    WouldBlock,
    OutOfMemory,
};

pub const Limits = struct {
    /// The longest protocol frame accepted on stdout.
    max_frame_bytes: usize = 1024 * 1024,
    /// The longest diagnostic line kept. Longer lines are truncated with a marker
    /// rather than read without bound.
    max_diagnostic_bytes: usize = 8 * 1024,
    /// How many diagnostic lines are buffered before the oldest are dropped.
    max_diagnostic_lines: usize = 256,
    /// How many protocol frames are buffered before the producer is told to wait.
    max_protocol_frames: usize = 64,
};

pub const Stream = enum { stdout, stderr };

pub const Diagnostic = struct {
    /// The line as kept, which may be shorter than the line as written.
    text: []u8,
    truncated: bool,

    pub fn deinit(self: Diagnostic, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
    }
};

/// The core's view of a plugin's output.
pub const Channel = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    /// Diagnostic lines dropped because the buffer was full.
    dropped_diagnostics: usize = 0,
    frames: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, limits: Limits) Channel {
        return .{ .gpa = gpa, .limits = limits };
    }

    pub fn deinit(self: *Channel) void {
        for (self.diagnostics.items) |diagnostic| diagnostic.deinit(self.gpa);
        self.diagnostics.deinit(self.gpa);
        for (self.frames.items) |frame| self.gpa.free(frame);
        self.frames.deinit(self.gpa);
    }

    /// Accepts one line from a named stream.
    ///
    /// A line on stderr is a diagnostic. A line on stdout must be a frame, and a line
    /// that is not a frame means the protocol stream carries something that is not
    /// protocol - reported, never parsed.
    pub fn accept(self: *Channel, stream: Stream, line: []const u8) Error!void {
        switch (stream) {
            .stderr => try self.acceptDiagnostic(line),
            .stdout => {
                if (line.len > self.limits.max_frame_bytes) return error.ProtocolContaminated;
                if (!(std.json.validate(self.gpa, line) catch return error.OutOfMemory)) {
                    return error.ProtocolContaminated;
                }
                try self.frames.append(self.gpa, try self.gpa.dupe(u8, line));
            },
        }
    }

    fn acceptDiagnostic(self: *Channel, line: []const u8) Error!void {
        // The line is bounded before it is stored, so a plugin cannot make the core
        // allocate an unbounded amount of memory by never emitting a newline.
        const truncated = line.len > self.limits.max_diagnostic_bytes;
        const kept = if (truncated) line[0..self.limits.max_diagnostic_bytes] else line;

        // A full diagnostics buffer drops the *oldest* line and counts the loss; it
        // never blocks the plugin, because a log line is not worth stalling a build.
        while (self.diagnostics.items.len >= self.limits.max_diagnostic_lines) {
            const oldest = self.diagnostics.orderedRemove(0);
            oldest.deinit(self.gpa);
            self.dropped_diagnostics += 1;
        }
        try self.diagnostics.append(self.gpa, .{
            .text = try self.gpa.dupe(u8, kept),
            .truncated = truncated,
        });
    }

    /// Produces a protocol frame, applying backpressure when the buffer is full.
    /// Frames are never dropped: the producer is told to wait instead.
    pub fn produce(self: *Channel, frame: []const u8) Error!void {
        if (self.frames.items.len >= self.limits.max_protocol_frames) return error.WouldBlock;
        try self.frames.append(self.gpa, try self.gpa.dupe(u8, frame));
    }

    /// Consumes one frame, which is how the buffer drains and a blocked producer
    /// resumes.
    pub fn consume(self: *Channel) ?[]u8 {
        if (self.frames.items.len == 0) return null;
        const frame = self.frames.orderedRemove(0);
        return frame;
    }

    pub fn diagnosticCount(self: *Channel) usize {
        return self.diagnostics.items.len;
    }
};

test "m13/PLUGIN-003 separate diagnostics, m13/PLUGIN-004 backpressure" {
    std.debug.print("JCKG_EVIDENCE PLUGIN-003\n", .{});
    std.debug.print("JCKG_EVIDENCE PLUGIN-004\n", .{});
    const gpa = std.testing.allocator;

    // Mutable: the channel's methods take a mutable pointer, so the local cannot be
    // const even though the binding itself is never reassigned.
    var channel = Channel.init(gpa, .{
        .max_diagnostic_bytes = 64,
        .max_diagnostic_lines = 4,
        .max_protocol_frames = 3,
    });
    defer channel.deinit();

    // Diagnostics on stderr are kept, and stay within the line limit: a long line is
    // truncated with the fact recorded rather than read without bound.
    try channel.accept(.stderr, "compiling\n");
    const long_line = try gpa.alloc(u8, 300);
    defer gpa.free(long_line);
    @memset(long_line, 'x');
    try channel.accept(.stderr, long_line);
    try std.testing.expectEqual(@as(usize, 2), channel.diagnosticCount());
    try std.testing.expect(channel.diagnostics.items[1].truncated);
    try std.testing.expectEqual(@as(usize, 64), channel.diagnostics.items[1].text.len);

    // A frame on stdout is protocol and is accepted as such.
    try channel.accept(.stdout, "{\"event\":\"progress\"}");

    // The failure this module exists to prevent: a plugin writes a log line to the
    // protocol stream. It is reported, not parsed and not resynchronized around.
    try std.testing.expectError(error.ProtocolContaminated, channel.accept(.stdout, "warning: something happened"));
    // A frame longer than the frame limit is contamination too - it cannot be a
    // document the core would accept.
    const huge = try gpa.alloc(u8, 1024 * 1024 + 8);
    defer gpa.free(huge);
    @memset(huge, 'a');
    try std.testing.expectError(error.ProtocolContaminated, channel.accept(.stdout, huge));

    // The diagnostics buffer is bounded: past its limit the oldest lines are dropped
    // and the count says how many, so the loss is visible rather than implied.
    try channel.accept(.stderr, "second\n");
    try channel.accept(.stderr, "third\n");
    try channel.accept(.stderr, "fourth\n");
    try channel.accept(.stderr, "fifth\n");
    try std.testing.expectEqual(@as(usize, 4), channel.diagnosticCount());
    try std.testing.expectEqual(@as(usize, 2), channel.dropped_diagnostics);
    // The two oldest lines went: the first diagnostic and the truncated one, so the
    // buffer now holds the four most recent.
    try std.testing.expectEqualStrings("second\n", channel.diagnostics.items[0].text);
    try std.testing.expectEqualStrings("fifth\n", channel.diagnostics.items[3].text);

    // Protocol frames are never dropped: the producer is told to wait when the
    // buffer is full, which is backpressure rather than data loss.
    try channel.produce("{\"event\":\"a\"}");
    try channel.produce("{\"event\":\"b\"}");
    try std.testing.expectError(error.WouldBlock, channel.produce("{\"event\":\"c\"}"));

    // Reading one frame is what lets a blocked producer make progress again - the
    // exchange advances rather than deadlocking.
    const drained = channel.consume().?;
    defer gpa.free(drained);
    try std.testing.expectEqualStrings("{\"event\":\"progress\"}", drained);
    try channel.produce("{\"event\":\"c\"}");

    // The frames queued are exactly the ones produced, in order, with none lost.
    const expected = [_][]const u8{ "{\"event\":\"a\"}", "{\"event\":\"b\"}", "{\"event\":\"c\"}" };
    for (expected) |want| {
        const frame = channel.consume().?;
        defer gpa.free(frame);
        try std.testing.expectEqualStrings(want, frame);
    }
    try std.testing.expect(channel.consume() == null);

    // An empty line on stdout is contamination rather than an empty frame.
    try std.testing.expectError(error.ProtocolContaminated, channel.accept(.stdout, ""));
}
