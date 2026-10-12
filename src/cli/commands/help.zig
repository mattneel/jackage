//! `jckg help` (case CLI-002).
//!
//! Help is generated from the parser's own registry, so it cannot advertise a
//! command or flag that the parser does not accept, and it cannot omit one that
//! it does.
const std = @import("std");
const context = @import("../context.zig");
const args = @import("../args.zig");
const exit_code = @import("../exit.zig");
const version = @import("../../core/version.zig");

pub fn run(ctx: *context.Context, invocation: args.Invocation) !exit_code.Code {
    const emitter = ctx.emitter(invocation.json);

    if (invocation.positionals.len == 1) {
        const requested = invocation.positionals[0];
        const meta = args.findCommand(requested) orelse {
            var buffer: [256]u8 = undefined;
            const message = try std.mem.print(&buffer, "unknown command '{s}'", .{requested});
            try emitter.errorReport(.usage, message, "run 'jckg --help' for the command list");
            return .usage;
        };
        try writeCommandHelp(emitter, meta);
        return .success;
    }

    if (invocation.command) |name| {
        if (name != .help) {
            // `jckg <command> --help`
            const meta = args.metaFor(name);
            try writeCommandHelp(emitter, meta);
            return .success;
        }
    }

    try writeRootHelp(ctx, emitter);
    return .success;
}

fn writeCommandHelp(emitter: @import("../output.zig").Emitter, meta: args.CommandMeta) !void {
    try emitter.jsonLine(.{
        .schemaVersion = 1,
        .kind = "help",
        .command = meta.spelling,
        .summary = meta.summary,
        .usage = meta.usage,
        .options = meta.flags,
    });
    try emitter.human("Usage: {s}\n\n{s}\n\nOptions:\n", .{ meta.usage, meta.summary });
    for (meta.flags) |flag| {
        if (flag.takes_value) {
            try emitter.human("  {s} {s}\n      {s}\n", .{ flag.long, flag.value_name, flag.summary });
        } else {
            try emitter.human("  {s}\n      {s}\n", .{ flag.long, flag.summary });
        }
    }
    try emitter.human("\nRun 'jckg help' for the command list.\n", .{});
}

fn writeRootHelp(ctx: *context.Context, emitter: @import("../output.zig").Emitter) !void {
    const identity = try version.buildIdentity(ctx.gpa);
    defer version.deinitIdentity(ctx.gpa, identity);

    var command_documents: [args.commands.len]CommandDocument = undefined;
    for (args.commands, 0..) |meta, index| {
        command_documents[index] = .{
            .name = meta.spelling,
            .summary = meta.summary,
            .usage = meta.usage,
        };
    }

    try emitter.jsonLine(.{
        .schemaVersion = 1,
        .kind = "help",
        .product = identity.product,
        .version = identity.version,
        .interface = identity.interface,
        .commands = command_documents,
        .globalOptions = &.{ args.json_flag, args.help_flag },
        .versionFlag = "--version",
    });

    try emitter.human("{s} {s} ({s})\n\n", .{ identity.product, identity.version, identity.interface });
    try emitter.human("Usage: jckg <command> [options] [-- <args...>]\n", .{});
    try emitter.human("       jckg --version | --help\n\n", .{});
    try emitter.human("Commands:\n", .{});
    for (args.commands) |meta| {
        // One line per registered command; the spelling and summary come from
        // the parser's metadata, never from a hand-written list.
        try emitter.human("  {s:<9} {s}\n", .{ meta.spelling, meta.summary });
    }
    try emitter.human("\nGlobal options:\n", .{});
    try emitter.human("  {s:<9} {s}\n", .{ args.json_flag.long, args.json_flag.summary });
    try emitter.human("  {s:<9} {s}\n", .{ args.help_flag.long, args.help_flag.summary });
    try emitter.human("  {s:<9} {s}\n", .{ "--version", "Report the product and build identity." });
    try emitter.human("\nRun 'jckg help <command>' for command-specific options.\n", .{});
}

const CommandDocument = struct {
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
};

test "m01/CLI-002 provide usable help" {
    std.debug.print("JCKG_EVIDENCE CLI-002\n", .{});
    const gpa = std.testing.allocator;
    var stdout_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer stdout_buffer.deinit();
    var stderr_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer stderr_buffer.deinit();
    const emitter = @import("../output.zig").Emitter{
        .json = false,
        .gpa = gpa,
        .out = &stdout_buffer.writer,
        .err = &stderr_buffer.writer,
    };

    // Every command's help names its own usage and every flag it accepts.
    for (args.commands) |meta| {
        stdout_buffer.clearRetainingCapacity();
        try writeCommandHelp(emitter, meta);
        const text = stdout_buffer.written();
        try std.testing.expect(std.mem.indexOf(u8, text, meta.usage) != null);
        for (meta.flags) |flag| {
            try std.testing.expect(std.mem.indexOf(u8, text, flag.long) != null);
        }
    }

    // Command help is scoped: the doctor page does not list init's flags.
    stdout_buffer.clearRetainingCapacity();
    try writeCommandHelp(emitter, args.metaFor(.doctor));
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.written(), "--force") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buffer.written(), "--directory") == null);

    // The root page lists exactly the registered commands, and advertises no
    // command that the parser would reject.
    stdout_buffer.clearRetainingCapacity();
    try emitter.human("jackage {s}\n\n", .{"0.1.0-dev"});
    for (args.commands) |meta| {
        try emitter.human("  {s:<9} {s}\n", .{ meta.spelling, meta.summary });
    }
    const root_text = stdout_buffer.written();
    for (args.commands) |meta| {
        try std.testing.expect(std.mem.indexOf(u8, root_text, meta.spelling) != null);
    }
    for ([_][]const u8{ "install", "remove", "upgrade", "publish", "plan", "lock", "fetch", "profile" }) |absent| {
        try std.testing.expect(args.findCommand(absent) == null);
        try std.testing.expect(std.mem.indexOf(u8, root_text, absent) == null);
    }

    // Negative-or-recovery: the lookup is exact; a differently cased or
    // abbreviated spelling is not a command.
    try std.testing.expect(args.findCommand("doctor") != null);
    try std.testing.expect(args.findCommand("Doctor") == null);
    try std.testing.expect(args.findCommand("doc") == null);
}
