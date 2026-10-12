//! `jckg` — the Jackage client.
//!
//! This file is only process plumbing: it takes the pinned toolchain's
//! `std.process.Init`, wires stdout/stderr, stdin, and the interrupt handler,
//! and hands control to `app.run`. Every behavior lives in the library.
const std = @import("std");
const app = @import("app.zig");
const context = @import("context.zig");
const console = @import("console.zig");
const exit_code = @import("exit.zig");
const cancel = @import("../core/cancel.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    // `Args.toSlice` yields sentinel-terminated entries; the context works on
    // ordinary slices of the same bytes.
    const raw_argv = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, raw_argv.len);
    for (raw_argv, 0..) |argument, index| argv[index] = argument;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [8192]u8 = undefined;
    var stderr_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);

    var token: cancel.Token = .{};
    // The handler only sets the flag; commands poll it at defined boundaries.
    _ = console.install(&token);

    // A non-terminal stdin can never answer a prompt, and commands must know
    // that before they decide anything.
    const interactive = std.Io.File.stdin().isTty(io) catch false;

    var stdin_buffer: [64]u8 = undefined;
    var stdin_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);

    var ctx: context.Context = .{
        .gpa = gpa,
        .io = io,
        .argv = argv,
        .cwd = std.Io.Dir.cwd(),
        .env = init.environ_map,
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
        .cancel_token = &token,
        .interactive = interactive,
        .stdin = &stdin_reader.interface,
    };

    const code = app.run(&ctx) catch |err| blk: {
        // Last-resort path: report through stderr and keep the exit code
        // meaningful. The structured document could not be produced because
        // the failure happened below the emitter.
        const emitter = ctx.emitter(false);
        emitter.errorReport(.infrastructure, "unexpected internal error", @errorName(err)) catch {};
        break :blk exit_code.Code.infrastructure;
    };

    // Flush before exiting: `std.process.exit` does not run deferred flushes.
    stdout_writer.interface.flush() catch {};
    stderr_writer.interface.flush() catch {};
    console.uninstall();
    std.process.exit(code.number());
}
