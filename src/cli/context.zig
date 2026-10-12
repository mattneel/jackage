//! Runtime context shared by the `jckg` commands.
const std = @import("std");
const cancel = @import("../core/cancel.zig");
const output = @import("output.zig");

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Full argument vector, including the program name.
    argv: []const []const u8,
    /// Directory the command operates in.
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// Set when the user interrupts or asks for cancellation.
    cancel_token: *cancel.Token,
    /// Whether stdin is an interactive terminal. When false, no command may
    /// wait for a human.
    interactive: bool,
    /// Present only when the caller supplied a readable stdin for the
    /// documented `--cancel-on-stdin` trigger.
    stdin: ?*std.Io.Reader,

    pub fn emitter(self: *Context, json: bool) output.Emitter {
        return .{ .json = json, .gpa = self.gpa, .out = self.out, .err = self.err };
    }

    /// Value of an environment variable, or null. Values are never printed;
    /// only presence and redacted descriptions may appear in diagnostics.
    pub fn envValue(self: *Context, name: []const u8) ?[]const u8 {
        return self.env.get(name);
    }
};

var stdin_token: ?*cancel.Token = null;

fn watchStdin(reader: *std.Io.Reader) void {
    _ = reader.takeByte() catch return;
    if (stdin_token) |token| token.request();
}

/// Starts the documented `--cancel-on-stdin` trigger. Returns false when no
/// stdin reader was supplied, so the caller can report that honestly instead
/// of promising a trigger that cannot fire.
pub fn startStdinWatcher(ctx: *Context) bool {
    const reader = ctx.stdin orelse return false;
    stdin_token = ctx.cancel_token;
    const thread = std.Thread.spawn(.{}, watchStdin, .{reader}) catch return false;
    thread.detach();
    return true;
}
