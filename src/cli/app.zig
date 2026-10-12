//! Command dispatch for the `jckg` client.
//!
//! Parsing happens once, before any command runs, so a malformed request can
//! never produce a partial side effect.
const std = @import("std");
const args = @import("args.zig");
const context = @import("context.zig");
const exit_code = @import("exit.zig");
const help_command = @import("commands/help.zig");
const version_command = @import("commands/version.zig");
const doctor_command = @import("commands/doctor.zig");
const init_command = @import("commands/init.zig");
const echo_command = @import("commands/echo.zig");

pub fn run(ctx: *context.Context) !exit_code.Code {
    // The whole argv is parsed before any command body executes.
    var invocation: args.Invocation = .{};
    var diagnostic: args.Diagnostic = .{};
    args.parse(ctx.gpa, ctx.argv, &invocation, &diagnostic) catch |err| switch (err) {
        error.OutOfMemory => {
            const emitter = ctx.emitter(invocation.json);
            try emitter.errorReport(.infrastructure, "out of memory while parsing arguments", null);
            return .infrastructure;
        },
        else => |parse_error| return reportParseError(ctx, invocation.json, parse_error, diagnostic),
    };
    defer invocation.deinit(ctx.gpa);

    return dispatch(ctx, invocation) catch |err| {
        const emitter = ctx.emitter(invocation.json);
        try emitter.errorReport(.infrastructure, "unexpected internal error", @errorName(err));
        return .infrastructure;
    };
}

fn dispatch(ctx: *context.Context, invocation: args.Invocation) !exit_code.Code {
    if (invocation.show_version) return version_command.run(ctx, invocation);
    if (invocation.show_help) return help_command.run(ctx, invocation);

    const command = invocation.command orelse return help_command.run(ctx, invocation);
    return switch (command) {
        .version => version_command.run(ctx, invocation),
        .help => help_command.run(ctx, invocation),
        .doctor => doctor_command.run(ctx, invocation),
        .init => init_command.run(ctx, invocation),
        .echo => echo_command.run(ctx, invocation),
    };
}

fn reportParseError(
    ctx: *context.Context,
    json: bool,
    err: args.ParseError,
    diagnostic: args.Diagnostic,
) !exit_code.Code {
    const emitter = ctx.emitter(json);
    var message_buffer: [256]u8 = undefined;
    var detail_storage: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer detail_storage.deinit();
    var detail: ?[]const u8 = null;

    const message = switch (err) {
        error.UnknownCommand => try std.mem.print(&message_buffer, "unknown command '{s}'", .{diagnostic.token}),
        error.UnknownFlag => if (diagnostic.command) |command|
            try std.mem.print(&message_buffer, "unknown flag '{s}' for 'jckg {s}'", .{ diagnostic.token, args.metaFor(command).spelling })
        else
            try std.mem.print(&message_buffer, "unknown flag '{s}'", .{diagnostic.token}),
        error.MissingValue => try std.mem.print(&message_buffer, "flag '{s}' needs a value", .{diagnostic.token}),
        error.InvalidValue => try std.mem.print(&message_buffer, "flag '{s}' has an invalid value", .{diagnostic.token}),
        error.UnexpectedArgument => try std.mem.print(&message_buffer, "unexpected argument '{s}'", .{diagnostic.token}),
    };

    switch (err) {
        error.UnknownCommand => detail = "run 'jckg --help' for the command list",
        error.UnknownFlag => {
            try detail_storage.writer.writeAll("accepted flags:");
            for (diagnostic.known_flags) |flag| {
                try detail_storage.writer.print(" {s}", .{flag.long});
            }
            detail = detail_storage.written();
        },
        error.MissingValue, error.InvalidValue => {
            try detail_storage.writer.writeAll("run 'jckg help");
            if (diagnostic.command) |command| {
                try detail_storage.writer.print(" {s}", .{args.metaFor(command).spelling});
            }
            try detail_storage.writer.writeAll("' for usage");
            detail = detail_storage.written();
        },
        error.UnexpectedArgument => detail = "see the command usage; use '--' to pass arguments to a program",
    }

    try emitter.errorReport(.usage, message, detail);
    return .usage;
}
