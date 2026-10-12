//! Command-line parsing for `jckg` (cases CLI-002, CLI-004, CLI-005).
//!
//! The parser is explicit: every accepted flag is declared in a registry that
//! help is generated from, unknown input is a usage error rather than a guess,
//! and `--` hands the remaining tokens to the target program untouched. The
//! parser never expands, splits, or shell-evaluates an argument.
const std = @import("std");

pub const CommandName = enum { version, help, doctor, init, echo };

pub const FlagSpec = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    takes_value: bool = false,
    value_name: []const u8 = "",
    summary: []const u8,
    /// Accepted before and after the command name.
    global: bool = false,
};

pub const json_flag = FlagSpec{ .long = "--json", .summary = "Write structured JSON to stdout; progress stays on stderr.", .global = true };
pub const help_flag = FlagSpec{ .long = "--help", .short = "-h", .summary = "Show help for this command.", .global = true };
pub const yes_flag = FlagSpec{ .long = "--yes", .summary = "Approve this local action without a terminal prompt.", .global = true };
const force_flag = FlagSpec{ .long = "--force", .summary = "Replace existing declarations (requires authorization)." };
const directory_flag = FlagSpec{ .long = "--directory", .takes_value = true, .value_name = "<path>", .summary = "Directory to initialize instead of the working directory." };
const watch_flag = FlagSpec{ .long = "--watch", .summary = "Repeat the report until canceled or the deadline passes." };
const deadline_flag = FlagSpec{ .long = "--deadline-ms", .takes_value = true, .value_name = "<milliseconds>", .summary = "Stop watching after this time budget." };
const cancel_stdin_flag = FlagSpec{ .long = "--cancel-on-stdin", .summary = "Stop when any byte arrives on stdin." };
const repo_flag = FlagSpec{ .long = "--repo", .takes_value = true, .value_name = "<url>", .summary = "Report on a repository locator (credentials are never printed)." };

pub const CommandMeta = struct {
    name: CommandName,
    spelling: []const u8,
    summary: []const u8,
    usage: []const u8,
    flags: []const FlagSpec,
};

pub const commands = [_]CommandMeta{
    .{
        .name = .version,
        .spelling = "version",
        .summary = "Report the product and build identity.",
        .usage = "jckg version [--json]",
        .flags = &.{ json_flag, help_flag },
    },
    .{
        .name = .help,
        .spelling = "help",
        .summary = "Show the command list or one command's help.",
        .usage = "jckg help [<command>] [--json]",
        .flags = &.{ json_flag, help_flag },
    },
    .{
        .name = .doctor,
        .spelling = "doctor",
        .summary = "Report host, toolchain, audit, and backend capabilities.",
        .usage = "jckg doctor [--watch] [--deadline-ms <ms>] [--cancel-on-stdin] [--repo <url>] [--json]",
        .flags = &.{ json_flag, help_flag, watch_flag, deadline_flag, cancel_stdin_flag, repo_flag },
    },
    .{
        .name = .init,
        .spelling = "init",
        .summary = "Create project declarations without overwriting existing files.",
        .usage = "jckg init [--directory <path>] [--force] [--yes] [--json]",
        .flags = &.{ json_flag, help_flag, directory_flag, force_flag, yes_flag },
    },
    .{
        .name = .echo,
        .spelling = "echo",
        .summary = "Print the exact argv this process received (argument-boundary diagnostic).",
        .usage = "jckg echo [--json] [-- <args...>]",
        .flags = &.{ json_flag, help_flag },
    },
};

pub fn findCommand(spelling: []const u8) ?CommandMeta {
    for (commands) |meta| {
        if (std.mem.eql(u8, meta.spelling, spelling)) return meta;
    }
    return null;
}

pub fn metaFor(name: CommandName) CommandMeta {
    for (commands) |meta| {
        if (meta.name == name) return meta;
    }
    unreachable;
}

pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    InvalidValue,
    UnexpectedArgument,
};

/// What went wrong, in terms the caller can print and act on.
pub const Diagnostic = struct {
    kind: ParseError = error.UnknownFlag,
    token: []const u8 = "",
    command: ?CommandName = null,
    /// Flags the caller could have used, for the suggestion line.
    known_flags: []const FlagSpec = &.{},
};

pub const Invocation = struct {
    command: ?CommandName = null,
    json: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    assume_yes: bool = false,
    force: bool = false,
    watch: bool = false,
    cancel_on_stdin: bool = false,
    deadline_ms: ?u64 = null,
    directory: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},
    passthrough: []const []const u8 = &.{},

    pub fn deinit(self: Invocation, gpa: std.mem.Allocator) void {
        gpa.free(self.positionals);
        gpa.free(self.passthrough);
    }
};

fn flagsFor(command: ?CommandName) []const FlagSpec {
    if (command) |name| return metaFor(name).flags;
    return &.{ json_flag, help_flag };
}

fn findFlag(command: ?CommandName, spelling: []const u8) ?FlagSpec {
    for (flagsFor(command)) |spec| {
        if (std.mem.eql(u8, spec.long, spelling)) return spec;
        if (spec.short) |short| {
            if (std.mem.eql(u8, short, spelling)) return spec;
        }
    }
    return null;
}

fn setBoolFlag(out: *Invocation, spec: FlagSpec, diagnostic: *Diagnostic, token: []const u8) ParseError!void {
    if (std.mem.eql(u8, spec.long, "--json")) {
        out.json = true;
    } else if (std.mem.eql(u8, spec.long, "--help")) {
        out.show_help = true;
    } else if (std.mem.eql(u8, spec.long, "--yes")) {
        out.assume_yes = true;
    } else if (std.mem.eql(u8, spec.long, "--force")) {
        out.force = true;
    } else if (std.mem.eql(u8, spec.long, "--watch")) {
        out.watch = true;
    } else if (std.mem.eql(u8, spec.long, "--cancel-on-stdin")) {
        out.cancel_on_stdin = true;
    } else {
        diagnostic.token = token;
        return error.UnknownFlag;
    }
}

fn setValueFlag(out: *Invocation, spec: FlagSpec, value: []const u8, diagnostic: *Diagnostic, token: []const u8) ParseError!void {
    if (std.mem.eql(u8, spec.long, "--directory")) {
        out.directory = value;
    } else if (std.mem.eql(u8, spec.long, "--repo")) {
        if (value.len == 0) {
            diagnostic.token = token;
            return error.InvalidValue;
        }
        out.repo = value;
    } else if (std.mem.eql(u8, spec.long, "--deadline-ms")) {
        out.deadline_ms = std.fmt.parseInt(u64, value, 10) catch {
            diagnostic.token = token;
            return error.InvalidValue;
        };
    } else {
        diagnostic.token = token;
        return error.UnknownFlag;
    }
}

/// Parses an argument vector, excluding the program name in `argv[0]`.
pub fn parse(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    out: *Invocation,
    diagnostic: *Diagnostic,
) (ParseError || std.mem.Allocator.Error)!void {
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer positionals.deinit(gpa);
    var passthrough: std.ArrayList([]const u8) = .empty;
    errdefer passthrough.deinit(gpa);

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const token = argv[index];
        if (std.mem.eql(u8, token, "--")) {
            index += 1;
            while (index < argv.len) : (index += 1) try passthrough.append(gpa, argv[index]);
            break;
        }

        const is_flag = token.len > 1 and token[0] == '-';
        if (!is_flag) {
            if (out.command == null) {
                const meta = findCommand(token) orelse {
                    diagnostic.kind = error.UnknownCommand;
                    diagnostic.token = token;
                    return error.UnknownCommand;
                };
                out.command = meta.name;
            } else {
                try positionals.append(gpa, token);
            }
            continue;
        }

        if (std.mem.eql(u8, token, "--version") or std.mem.eql(u8, token, "-V")) {
            out.show_version = true;
            continue;
        }

        const equals = std.mem.indexOfScalar(u8, token, '=');
        const spelling = if (equals) |position| token[0..position] else token;
        const inline_value: ?[]const u8 = if (equals) |position| token[position + 1 ..] else null;

        const spec = findFlag(out.command, spelling) orelse {
            diagnostic.kind = error.UnknownFlag;
            diagnostic.token = token;
            diagnostic.command = out.command;
            diagnostic.known_flags = flagsFor(out.command);
            return error.UnknownFlag;
        };

        diagnostic.command = out.command;
        if (spec.takes_value) {
            const value = inline_value orelse blk: {
                index += 1;
                if (index >= argv.len) {
                    diagnostic.kind = error.MissingValue;
                    diagnostic.token = token;
                    return error.MissingValue;
                }
                break :blk argv[index];
            };
            try setValueFlag(out, spec, value, diagnostic, token);
        } else {
            if (inline_value != null) {
                diagnostic.kind = error.InvalidValue;
                diagnostic.token = token;
                return error.InvalidValue;
            }
            try setBoolFlag(out, spec, diagnostic, token);
        }
    }

    out.positionals = try positionals.toOwnedSlice(gpa);
    errdefer gpa.free(out.positionals);
    out.passthrough = try passthrough.toOwnedSlice(gpa);

    // Positional arguments belong to `echo` and `help` only; anything else is a
    // usage error rather than a silently ignored token.
    if (out.positionals.len > 0) {
        switch (out.command orelse .help) {
            .echo => {},
            .help => {
                if (out.positionals.len > 1) {
                    diagnostic.kind = error.UnexpectedArgument;
                    diagnostic.token = out.positionals[1];
                    return error.UnexpectedArgument;
                }
            },
            else => {
                diagnostic.kind = error.UnexpectedArgument;
                diagnostic.token = out.positionals[0];
                return error.UnexpectedArgument;
            },
        }
    }
}

test "m01/CLI-004 reject invalid syntax" {
    std.debug.print("JCKG_EVIDENCE CLI-004\n", .{});
    const gpa = std.testing.allocator;
    const argv_base = [_][]const u8{"jckg"};

    // Unknown command.
    {
        const argv = argv_base ++ [_][]const u8{"instal"};
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.UnknownCommand, parse(gpa, &argv, &invocation, &diagnostic));
        try std.testing.expectEqualStrings("instal", diagnostic.token);
    }

    // Unknown flag, with the command context and the flags that would work.
    {
        const argv = argv_base ++ [_][]const u8{ "doctor", "--jsno" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.UnknownFlag, parse(gpa, &argv, &invocation, &diagnostic));
        try std.testing.expectEqualStrings("--jsno", diagnostic.token);
        try std.testing.expectEqual(CommandName.doctor, diagnostic.command.?);
        try std.testing.expect(diagnostic.known_flags.len > 0);
    }

    // A flag that belongs to another command is not accepted here.
    {
        const argv = argv_base ++ [_][]const u8{ "version", "--force" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.UnknownFlag, parse(gpa, &argv, &invocation, &diagnostic));
    }

    // Missing and malformed values.
    {
        const argv = argv_base ++ [_][]const u8{ "doctor", "--deadline-ms" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.MissingValue, parse(gpa, &argv, &invocation, &diagnostic));
    }
    {
        const argv = argv_base ++ [_][]const u8{ "doctor", "--deadline-ms=soon" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidValue, parse(gpa, &argv, &invocation, &diagnostic));
    }
    {
        const argv = argv_base ++ [_][]const u8{ "doctor", "--json=yes" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.InvalidValue, parse(gpa, &argv, &invocation, &diagnostic));
    }

    // An unexpected positional argument is reported, not ignored.
    {
        const argv = argv_base ++ [_][]const u8{ "version", "extra" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try std.testing.expectError(error.UnexpectedArgument, parse(gpa, &argv, &invocation, &diagnostic));
        try std.testing.expectEqualStrings("extra", diagnostic.token);
    }

    // Negative-or-recovery: valid input still parses, including `--` handling
    // and both `--flag value` and `--flag=value`.
    {
        const argv = argv_base ++ [_][]const u8{ "doctor", "--json", "--deadline-ms=250", "--repo", "https://example.invalid/repo.git", "--watch" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try parse(gpa, &argv, &invocation, &diagnostic);
        defer invocation.deinit(gpa);
        try std.testing.expect(invocation.json);
        try std.testing.expect(invocation.watch);
        try std.testing.expectEqual(@as(?u64, 250), invocation.deadline_ms);
        try std.testing.expectEqualStrings("https://example.invalid/repo.git", invocation.repo.?);
    }
    {
        const argv = argv_base ++ [_][]const u8{ "--json", "echo", "--", "--json", "-x", "a b" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try parse(gpa, &argv, &invocation, &diagnostic);
        defer invocation.deinit(gpa);
        try std.testing.expectEqual(CommandName.echo, invocation.command.?);
        try std.testing.expect(invocation.json);
        try std.testing.expectEqual(@as(usize, 3), invocation.passthrough.len);
        try std.testing.expectEqualStrings("--json", invocation.passthrough[0]);
        try std.testing.expectEqualStrings("a b", invocation.passthrough[2]);
        // Tokens after `--` keep their boundaries: one element, not two.
        try std.testing.expectEqualStrings("a b", invocation.passthrough[2]);
    }
    {
        const argv = argv_base ++ [_][]const u8{ "help", "doctor" };
        var invocation: Invocation = .{};
        var diagnostic: Diagnostic = .{};
        try parse(gpa, &argv, &invocation, &diagnostic);
        defer invocation.deinit(gpa);
        try std.testing.expectEqual(CommandName.help, invocation.command.?);
        try std.testing.expectEqual(@as(usize, 1), invocation.positionals.len);
        try std.testing.expectEqualStrings("doctor", invocation.positionals[0]);
    }
}
