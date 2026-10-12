//! The contract between the core and a plugin process (M13, PLUGIN-001, PLUGIN-002).
//!
//! A plugin is a separate process speaking framed JSON over a pipe. Two decisions
//! here are load-bearing:
//!
//! - **Versions are negotiated before anything else happens.** The core and the
//!   plugin must agree on a major version, and the plugin's minor version must not
//!   exceed the core's: a plugin built against a newer contract needs features the
//!   core does not have, and the honest answer is to refuse rather than to try. When
//!   the handshake fails no action starts, so a version error is a refusal rather
//!   than a partially executed plan.
//! - **Frames are bounded before they are read.** The length prefix is checked
//!   against a limit *before* any allocation, so a plugin that declares a gigabyte
//!   is refused without the core reserving one. A frame that does not parse is
//!   rejected whole: nothing is dispatched from a partially valid document.
const std = @import("std");

pub const Error = error{
    IncompatibleMajor,
    UnsupportedMinor,
    FrameTooLarge,
    FrameTooShort,
    MalformedFrame,
    OutOfMemory,
};

pub const Version = struct {
    major: u32,
    minor: u32,
};

pub const Limits = struct {
    /// The largest frame body the core will read. The check happens against the
    /// declared length, so an oversized frame costs nothing to refuse.
    max_frame_bytes: usize = 1024 * 1024,
};

pub const Handshake = struct {
    core: Version,
    plugin: Version,
    /// The version both sides will speak: the core's, always, because the core
    /// defines the contract and the plugin declares a subset of it.
    negotiated: Version,
};

/// Negotiates a version, refusing an incompatible major or a plugin that needs a
/// newer minor contract than the core knows.
pub fn handshake(core: Version, plugin: Version) Error!Handshake {
    if (core.major != plugin.major) return error.IncompatibleMajor;
    // Same major, higher minor: the plugin was built against a contract this core
    // does not implement yet. Trying anyway would fail later, in the middle of an
    // action, where the failure is harder to explain.
    if (plugin.minor > core.minor) return error.UnsupportedMinor;
    return .{ .core = core, .plugin = plugin, .negotiated = core };
}

pub const Frame = struct {
    /// The parsed document, owned by the caller.
    body: []u8,

    pub fn deinit(self: Frame, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

/// Reads one frame: a decimal byte count, a newline, then exactly that many bytes.
///
/// The declared length is validated against the limit before the buffer is
/// allocated, which is what makes "oversized" a refusal rather than a memory
/// exhaustion, and the body must parse as JSON before it is returned, which is what
/// keeps a malformed document from being dispatched in part.
pub fn readFrame(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    limits: Limits,
) Error!Frame {
    // The length line is read into a small fixed buffer: an attacker cannot make the
    // header itself unbounded.
    var header: [32]u8 = undefined;
    var length: usize = 0;
    var digits: usize = 0;
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.MalformedFrame,
            else => return error.MalformedFrame,
        };
        if (byte == '\n') break;
        if (byte < '0' or byte > '9') return error.MalformedFrame;
        if (digits == header.len) return error.FrameTooLarge;
        header[digits] = byte;
        digits += 1;
        length = length * 10 + (byte - '0');
        // Checking inside the loop means a number with a million digits is refused on
        // the way in rather than after being assembled.
        if (length > limits.max_frame_bytes) return error.FrameTooLarge;
    }
    if (digits == 0) return error.MalformedFrame;

    const body = try gpa.alloc(u8, length);
    errdefer gpa.free(body);
    const read = reader.readSliceShort(body) catch return error.FrameTooShort;
    if (read != length) return error.FrameTooShort;

    // The body must be a complete JSON document. A truncated or malformed frame is
    // refused as a whole, so no dispatcher ever sees half of one.
    if (!(try std.json.validate(gpa, body))) return error.MalformedFrame;
    return .{ .body = body };
}

test "m13/PLUGIN-001 negotiate versions, m13/PLUGIN-002 bound frames" {
    std.debug.print("JCKG_EVIDENCE PLUGIN-001\n", .{});
    std.debug.print("JCKG_EVIDENCE PLUGIN-002\n", .{});
    const gpa = std.testing.allocator;

    const core = Version{ .major = 2, .minor = 5 };

    // Compatible: same major, older or equal minor.
    const exact = try handshake(core, .{ .major = 2, .minor = 5 });
    try std.testing.expectEqual(@as(u32, 2), exact.negotiated.major);
    const older = try handshake(core, .{ .major = 2, .minor = 3 });
    try std.testing.expectEqual(@as(u32, 2), older.negotiated.major);

    // An incompatible major is refused, and the result is an error rather than a
    // handshake the caller could mistake for success - so no action starts.
    try std.testing.expectError(error.IncompatibleMajor, handshake(core, .{ .major = 3, .minor = 0 }));
    try std.testing.expectError(error.IncompatibleMajor, handshake(core, .{ .major = 1, .minor = 9 }));
    // Same major but a newer minor contract: refused rather than attempted.
    try std.testing.expectError(error.UnsupportedMinor, handshake(core, .{ .major = 2, .minor = 6 }));

    const limits = Limits{ .max_frame_bytes = 4096 };

    // A valid frame parses and is returned whole.
    {
        const text = "18\n{\"action\":\"build\"}";
        var stream = std.Io.Reader.fixed(text);
        const frame = try readFrame(gpa, &stream, limits);
        defer frame.deinit(gpa);
        try std.testing.expectEqualStrings("{\"action\":\"build\"}", frame.body);
    }

    // An oversized declared length is refused before any allocation, and the body is
    // not read at all: the refusal costs nothing and cannot be turned into memory
    // exhaustion by a plugin that only writes a number.
    {
        const text = "999999999999\n";
        var stream = std.Io.Reader.fixed(text);
        try std.testing.expectError(error.FrameTooLarge, readFrame(gpa, &stream, limits));
    }
    // A length that is large but fitted inside the header digits is refused the same
    // way, so the check is on the number and not on how it was written.
    {
        try std.testing.expect(limits.max_frame_bytes < 100000);
        var stream = std.Io.Reader.fixed("100000\n");
        try std.testing.expectError(error.FrameTooLarge, readFrame(gpa, &stream, limits));
    }

    // Malformed bodies are refused as a whole: a truncated document, a sentence that
    // is not JSON, and a body shorter than its declared length.
    {
        var stream = std.Io.Reader.fixed("9\nnot json!");
        try std.testing.expectError(error.MalformedFrame, readFrame(gpa, &stream, limits));
    }
    {
        var stream = std.Io.Reader.fixed("3\n[1,");
        try std.testing.expectError(error.MalformedFrame, readFrame(gpa, &stream, limits));
    }
    {
        var stream = std.Io.Reader.fixed("20\n{\"a\":1}");
        try std.testing.expectError(error.FrameTooShort, readFrame(gpa, &stream, limits));
    }
    // A header that is not a number, and an empty header, are malformed rather than
    // guesses.
    {
        var stream = std.Io.Reader.fixed("abc\n{}");
        try std.testing.expectError(error.MalformedFrame, readFrame(gpa, &stream, limits));
    }
    {
        var stream = std.Io.Reader.fixed("\n{}");
        try std.testing.expectError(error.MalformedFrame, readFrame(gpa, &stream, limits));
    }
    // An empty stream ends the conversation rather than producing an empty frame.
    {
        var stream = std.Io.Reader.fixed("");
        try std.testing.expectError(error.MalformedFrame, readFrame(gpa, &stream, limits));
    }

    // A frame exactly at the limit is accepted: the bound is inclusive, and a
    // boundary that only works below itself is not a boundary anybody can rely on.
    {
        const padding = try gpa.alloc(u8, limits.max_frame_bytes);
        defer gpa.free(padding);
        @memset(padding, ' ');
        const body = try std.fmt.allocPrint(gpa, "[{s}]", .{padding[0 .. limits.max_frame_bytes - 2]});
        defer gpa.free(body);
        const text = try std.fmt.allocPrint(gpa, "{d}\n{s}", .{ body.len, body });
        defer gpa.free(text);
        var stream = std.Io.Reader.fixed(text);
        const frame = try readFrame(gpa, &stream, limits);
        defer frame.deinit(gpa);
        try std.testing.expectEqual(body.len, frame.body.len);
    }
}
