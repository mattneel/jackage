//! Output discipline for the client (case CLI-003).
//!
//! Structured mode keeps stdout free of prose: every line on stdout is one
//! JSON document, including failures, so a caller can parse the stream without
//! filtering. Human progress and diagnostics use stderr, and every message
//! passes through secret redaction before it is written.
const std = @import("std");
const exit_code = @import("exit.zig");
const redact = @import("../core/redact.zig");

pub const Emitter = struct {
    json: bool,
    /// Primary results: stdout.
    out: *std.Io.Writer,
    /// Progress and diagnostics: stderr.
    err: *std.Io.Writer,
    /// Staging allocator for redacting a message before it is written.
    gpa: std.mem.Allocator,

    pub fn progress(self: Emitter, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
        try self.err.print(format, args);
    }

    /// Writes a human-readable result line. In structured mode nothing is
    /// written: the caller emits a JSON document instead.
    pub fn human(self: Emitter, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
        if (self.json) return;
        try self.out.print(format, args);
    }

    /// Writes one JSON document followed by a newline. In human mode nothing is
    /// written: the caller uses `human` instead.
    pub fn jsonLine(self: Emitter, value: anytype) !void {
        if (!self.json) return;
        try std.json.Stringify.value(value, .{}, self.out);
        try self.out.writeByte('\n');
    }

    /// Reports a failure. Structured mode writes a JSON error document to
    /// stdout (so stdout stays parseable) and a redacted human line to stderr.
    pub fn errorReport(
        self: Emitter,
        code: exit_code.Code,
        message: []const u8,
        detail: ?[]const u8,
    ) !void {
        if (self.json) {
            var message_buffer: std.Io.Writer.Allocating = .init(self.gpa);
            defer message_buffer.deinit();
            try redact.redactInto(&message_buffer.writer, message);
            var detail_buffer: std.Io.Writer.Allocating = .init(self.gpa);
            defer detail_buffer.deinit();
            if (detail) |text| try redact.redactInto(&detail_buffer.writer, text);

            try self.jsonLine(.{
                .schemaVersion = 1,
                .kind = "error",
                .status = code.text(),
                .code = code.stableId(),
                .exitCode = code.number(),
                .message = message_buffer.written(),
                .detail = if (detail != null) detail_buffer.written() else null,
            });
        }
        try self.err.writeAll("error: ");
        try redact.redactInto(self.err, message);
        try self.err.writeByte('\n');
        if (detail) |text| {
            try self.err.writeAll("detail: ");
            try redact.redactInto(self.err, text);
            try self.err.writeByte('\n');
        }
    }
};

test "m01/CLI-003 separate JSON output" {
    const gpa = std.testing.allocator;
    var stdout_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer stderr_buffer.deinit();

    const structured = Emitter{ .json = true, .gpa = gpa, .out = &stdout_buffer.writer, .err = &stderr_buffer.writer };
    try structured.human("this must not reach stdout\n", .{});
    try structured.jsonLine(.{ .schemaVersion = 1, .kind = "version", .version = "0.1.0-dev" });
    try structured.progress("progress goes to stderr\n", .{});
    try structured.errorReport(exit_code.Code.usage, "unknown flag '--jsno'", "run 'jckg doctor --help'");
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.written(), "must not reach") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.written(), "progress") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buffer.written(), "progress goes to stderr") != null);

    // Every stdout line parses as JSON, including the failure document.
    var lines = std.mem.splitScalar(u8, stdout_buffer.written(), '\n');
    var documents: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const kind = parsed.value.object.get("kind").?;
        try std.testing.expect(kind == .string);
        documents += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), documents);

    // Human mode writes results to stdout and still diagnostics to stderr.
    var human_stdout: std.Io.Writer.Allocating = .init(gpa);
    defer human_stdout.deinit();
    var human_stderr: std.Io.Writer.Allocating = .init(gpa);
    defer human_stderr.deinit();
    const human = Emitter{ .json = false, .gpa = gpa, .out = &human_stdout.writer, .err = &human_stderr.writer };
    try human.human("jackage 0.1.0-dev\n", .{});
    try human.jsonLine(.{ .kind = "version" });
    try std.testing.expectEqualStrings("jackage 0.1.0-dev\n", human_stdout.written());

    // Negative-or-recovery: a message carrying a credential never reaches
    // either stream in clear text.
    var secret_stdout: std.Io.Writer.Allocating = .init(gpa);
    defer secret_stdout.deinit();
    var secret_stderr: std.Io.Writer.Allocating = .init(gpa);
    defer secret_stderr.deinit();
    const secret_emitter = Emitter{ .json = true, .gpa = gpa, .out = &secret_stdout.writer, .err = &secret_stderr.writer };
    try secret_emitter.errorReport(
        exit_code.Code.integrity,
        "cannot fetch https://user:ghp_abcdefghijklmnopqrstuvwx@example.invalid/asset",
        null,
    );
    try std.testing.expect(std.mem.indexOf(u8, secret_stdout.written(), "ghp_abcdefghijklmnopqrstuvwx") == null);
    try std.testing.expect(std.mem.indexOf(u8, secret_stderr.written(), "ghp_abcdefghijklmnopqrstuvwx") == null);
    try std.testing.expect(std.mem.indexOf(u8, secret_stdout.written(), "***@example.invalid") != null);

}
