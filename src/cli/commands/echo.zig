//! `jckg echo` — argument-boundary diagnostic (case CLI-005).
//!
//! Prints the argument vector this process received, in order, without
//! splitting, joining, quoting, or shell-expanding anything. It exists so that
//! argument boundaries can be verified against the real process, and so that a
//! user can see exactly what a later `jckg run <task> -- <args...>` will pass.
const std = @import("std");
const context = @import("../context.zig");
const args = @import("../args.zig");
const exit_code = @import("../exit.zig");

pub fn run(ctx: *context.Context, invocation: args.Invocation) !exit_code.Code {
    const emitter = ctx.emitter(invocation.json);

    // `jckg echo` writes the tokens it was given; with no tokens it prints the
    // program name only, which is still a real observation.
    var count: usize = 0;
    if (ctx.argv.len > 0) count += 1;
    count += invocation.positionals.len + invocation.passthrough.len;

    const tokens = try ctx.gpa.alloc(TokenDocument, count);
    defer ctx.gpa.free(tokens);
    var index: usize = 0;
    if (ctx.argv.len > 0) {
        tokens[index] = .{ .position = index, .value = ctx.argv[0], .origin = "program" };
        index += 1;
    }
    for (invocation.positionals) |value| {
        tokens[index] = .{ .position = index, .value = value, .origin = "argument" };
        index += 1;
    }
    for (invocation.passthrough) |value| {
        tokens[index] = .{ .position = index, .value = value, .origin = "passthrough" };
        index += 1;
    }

    try emitter.jsonLine(.{
        .schemaVersion = 1,
        .kind = "argv",
        .count = count,
        .tokens = tokens,
        .shellEvaluation = false,
    });

    for (tokens) |token| {
        try emitter.human("{d:>3}  {s}\n", .{ token.position, token.value });
    }
    return .success;
}

const TokenDocument = struct {
    position: usize,
    value: []const u8,
    origin: []const u8,
};
