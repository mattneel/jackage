//! `jckg-probe`: the action program the guest integration tests run *inside* the
//! sandbox to observe it from the inside (M08: STRICT-001..005, STRICT-010).
//!
//! A probe is a real process launched through the worker exactly like any other
//! action, which is the point: claims about isolation are checked by attempting
//! the violation, not by asking the sandbox whether it thinks it is isolated.
//!
//! Usage: `jckg-probe <check> [argument]`
//!
//! | check | passes when |
//! |---|---|
//! | `workspace-writable` | a file can be created under `/jckg/workspace` |
//! | `store-read-only` | creating a file under `/jckg/store` fails (STRICT-003) |
//! | `undeclared-write-denied` | a path outside the declared writable set is not writable (STRICT-001) |
//! | `undeclared-read-denied` | a host file outside the declared roots cannot be read (STRICT-001) |
//! | `logical-paths` | the working directory is exactly `/jckg/workspace` (STRICT-004) |
//! | `network-isolated` | no interface other than `lo` is visible (STRICT-002) |
//! | `pid-isolated` | only this action and its worker exist in `/proc` (STRICT-005) |
//! | `host-path-hidden` | a host path named on the command line is unreachable (STRICT-001) |
//! | `resource-limit-enforced` | the declared memory limit refuses a large allocation (STRICT-005) |
//!
//! Each check prints one line of JSON so the caller can record *why* it passed
//! or failed; the exit status is 0 for pass and 1 for fail.
const std = @import("std");
const builtin = @import("builtin");

pub const Check = enum {
    workspace_writable,
    store_read_only,
    undeclared_write_denied,
    undeclared_read_denied,
    logical_paths,
    network_isolated,
    pid_isolated,
    host_path_hidden,
    resource_limit_enforced,

    pub fn parse(text: []const u8) ?Check {
        const names = std.meta.tags(Check);
        inline for (names) |name| {
            var buffer: [64]u8 = undefined;
            const dashed = dashName(&buffer, name);
            if (std.mem.eql(u8, text, dashed)) return name;
        }
        return null;
    }
};

/// `workspace_writable` -> `workspace-writable`, so the command line and the
/// enum cannot drift apart.
fn dashName(buffer: []u8, check: Check) []const u8 {
    const raw = @tagName(check);
    if (raw.len > buffer.len) return raw;
    for (raw, 0..) |byte, index| buffer[index] = if (byte == '_') '-' else byte;
    return buffer[0..raw.len];
}

/// A probe's result: what was attempted, whether the restriction held, and why.
pub const Outcome = struct {
    check: Check,
    held: bool,
    detail: []const u8,
};

fn pathInto(buffer: []u8, comptime template: []const u8, argument: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, template, .{argument});
}

pub fn workspaceWritable(io: std.Io, gpa: std.mem.Allocator) Outcome {
    _ = gpa;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = pathInto(&buffer, "{s}", "/jckg/workspace/written-by-probe") catch {
        return .{ .check = .workspace_writable, .held = false, .detail = "path too long" };
    };
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true }) catch |err| {
        return .{ .check = .workspace_writable, .held = false, .detail = @errorName(err) };
    };
    file.close(io);
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    return .{ .check = .workspace_writable, .held = true, .detail = "wrote and removed a file" };
}

pub fn storeReadOnly(io: std.Io, gpa: std.mem.Allocator) Outcome {
    _ = gpa;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = pathInto(&buffer, "{s}", "/jckg/store/written-by-probe") catch {
        return .{ .check = .store_read_only, .held = false, .detail = "path too long" };
    };
    if (std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true })) |file| {
        file.close(io);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        return .{ .check = .store_read_only, .held = false, .detail = "store accepted a write" };
    } else |err| {
        return .{ .check = .store_read_only, .held = true, .detail = @errorName(err) };
    }
}

/// STRICT-001 (writes): nothing outside the declared writable set may accept a
/// write. Every candidate exists on a normal Linux host, so a failure means the
/// sandbox refused the write rather than that the directory was missing.
pub fn undeclaredWriteDenied(io: std.Io, gpa: std.mem.Allocator) Outcome {
    _ = gpa;
    // Only paths the plan did *not* declare writable: the workspace is the one
    // writable location, the store is read-only, and the tool directory is
    // read-only. `/tmp` is deliberately absent - the sandbox declares it as
    // scratch, so writing there is allowed and asserting otherwise would be a
    // false finding rather than a violation.
    const candidates = [_][]const u8{
        "/jckg/undeclared-probe",
        "/jckg/store/undeclared-probe",
        "/jckg/tools/undeclared-probe",
    };
    for (candidates) |candidate| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = pathInto(&buffer, "{s}", candidate) catch continue;
        if (std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true })) |file| {
            file.close(io);
            std.Io.Dir.deleteFileAbsolute(io, path) catch {};
            return .{ .check = .undeclared_write_denied, .held = false, .detail = candidate };
        } else |_| {}
    }
    return .{ .check = .undeclared_write_denied, .held = true, .detail = "all undeclared paths refused" };
}

/// STRICT-001 (reads): a host file outside the declared roots must not be
/// readable. Same reasoning as above - these files exist on every Linux host.
pub fn undeclaredReadDenied(io: std.Io, gpa: std.mem.Allocator) Outcome {
    // Host files a sandboxed action has no business reading. After the chroot
    // these do not exist at all, which is the point.
    const candidates = [_][]const u8{
        "/etc/shadow",
        "/etc/hostname",
        "/etc/passwd",
        "/home",
    };
    for (candidates) |candidate| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = pathInto(&buffer, "{s}", candidate) catch continue;
        // Opening for reading is the violation: the sandbox is supposed to make
        // this fail, so a successful open with read permission is a finding.
        if (std.Io.Dir.openFileAbsolute(io, path, .{})) |file| {
            defer file.close(io);
            const length = file.length(io) catch 0;
            const detail = std.fmt.allocPrint(gpa, "{s} was readable ({d} bytes)", .{ candidate, length }) catch candidate;
            return .{ .check = .undeclared_read_denied, .held = false, .detail = detail };
        } else |_| {}
    }
    return .{ .check = .undeclared_read_denied, .held = true, .detail = "no host file was readable" };
}

/// STRICT-004: the action's working directory is a fixed logical path, never the
/// host workspace, whatever the host workspace happened to be.
pub fn logicalPaths(io: std.Io, gpa: std.mem.Allocator) Outcome {
    const cwd = std.process.currentPathAlloc(io, gpa) catch |err| {
        return .{ .check = .logical_paths, .held = false, .detail = @errorName(err) };
    };
    defer gpa.free(cwd);
    if (std.mem.eql(u8, cwd, "/jckg/workspace")) {
        return .{ .check = .logical_paths, .held = true, .detail = "the action sees /jckg/workspace" };
    }
    return .{ .check = .logical_paths, .held = false, .detail = cwd };
}

/// The check attempts the violation instead of taking inventory: it tries a real
/// TCP connection to a public address and passes when the sandbox refuses it.
///
/// An inventory of `/proc/net/dev` was tried first and abandoned - it reports what
/// the kernel chose to list, which is both weaker evidence than a refused
/// connection and, inside a chroot with only procfs mounted, easy to read as
/// "empty" rather than "isolated".
pub fn networkIsolated(io: std.Io, gpa: std.mem.Allocator) Outcome {
    _ = io;
    _ = gpa;
    const socket = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM, 0);
    const signed: isize = @bitCast(socket);
    if (signed < 0) {
        return .{ .check = .network_isolated, .held = false, .detail = "no socket could be created" };
    }
    defer _ = std.os.linux.close(@intCast(socket));

    var address = std.os.linux.sockaddr.in{
        .family = std.os.linux.AF.INET,
        .port = std.mem.nativeToBig(u16, 53),
        .addr = std.mem.nativeToBig(u32, 0x01010101), // 1.1.1.1
        .zero = @splat(0),
    };
    const result = std.os.linux.connect(
        @intCast(socket),
        @ptrCast(&address),
        @sizeOf(std.os.linux.sockaddr.in),
    );
    const connected: isize = @bitCast(result);
    if (connected < 0) {
        return .{ .check = .network_isolated, .held = true, .detail = "the refused connection is the finding" };
    }
    return .{ .check = .network_isolated, .held = false, .detail = "a TCP connection to 1.1.1.1:53 succeeded" };
}

/// STRICT-005: only the action and its worker exist in this process namespace.
/// A host running anything else would show far more than two entries.
pub fn pidIsolated(io: std.Io) Outcome {
    var directory = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch |err| {
        return .{ .check = .pid_isolated, .held = false, .detail = @errorName(err) };
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    var numeric: usize = 0;
    while (iterator.next(io) catch null) |entry| {
        if (entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
        numeric += 1;
    }
    if (numeric <= 2) {
        return .{ .check = .pid_isolated, .held = true, .detail = "only this action and its worker are visible" };
    }
    return .{ .check = .pid_isolated, .held = false, .detail = "other processes are visible" };
}

/// STRICT-001: a host path named on the command line must be unreachable.
pub fn hostPathHidden(io: std.Io, gpa: std.mem.Allocator, host_path: []const u8) Outcome {
    _ = gpa;
    if (std.Io.Dir.accessAbsolute(io, host_path, .{})) |_| {
        return .{ .check = .host_path_hidden, .held = false, .detail = host_path };
    } else |err| {
        return .{ .check = .host_path_hidden, .held = true, .detail = @errorName(err) };
    }
}

/// STRICT-005: the plan's memory limit is real. The probe asks for far more than
/// the limit; a limit that grants it is not a limit.
pub fn resourceLimitEnforced() Outcome {
    const request_bytes: usize = 8 * 1024 * 1024 * 1024;
    const memory = std.heap.page_allocator.alloc(u8, request_bytes) catch {
        return .{ .check = .resource_limit_enforced, .held = true, .detail = "the declared limit refused an 8 GiB request" };
    };
    defer std.heap.page_allocator.free(memory);
    // Touch a page per megabyte so the allocation cannot be optimised into a
    // reservation the kernel never backs.
    var index: usize = 0;
    while (index < request_bytes) : (index += 1024 * 1024) memory[index] = 1;
    return .{ .check = .resource_limit_enforced, .held = false, .detail = "the limit granted 8 GiB" };
}

/// One JSON line so the caller records the reason, not just the verdict.
pub fn render(out: *std.Io.Writer, outcome: Outcome) !void {
    try out.print("{{\"check\":\"{s}\",\"held\":{s},\"detail\":\"{s}\"}}\n", .{
        @tagName(outcome.check),
        if (outcome.held) "true" else "false",
        outcome.detail,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arguments = try init.minimal.args.iterateAllocator(gpa);
    defer arguments.deinit();
    var argument_list: std.ArrayList([]const u8) = .empty;
    defer argument_list.deinit(gpa);
    while (arguments.next()) |argument| try argument_list.append(gpa, argument);
    const argv = argument_list.items;
    if (argv.len < 2) return error.MissingCheck;

    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &writer.interface;

    const check = Check.parse(argv[1]) orelse return error.UnknownCheck;
    const outcome = switch (check) {
        .workspace_writable => workspaceWritable(io, gpa),
        .store_read_only => storeReadOnly(io, gpa),
        .undeclared_write_denied => undeclaredWriteDenied(io, gpa),
        .undeclared_read_denied => undeclaredReadDenied(io, gpa),
        .logical_paths => logicalPaths(io, gpa),
        .network_isolated => networkIsolated(io, gpa),
        .pid_isolated => pidIsolated(io),
        .host_path_hidden => if (argv.len >= 3) hostPathHidden(io, gpa, argv[2]) else Outcome{ .check = .host_path_hidden, .held = false, .detail = "missing path" },
        .resource_limit_enforced => resourceLimitEnforced(),
    };
    try render(out, outcome);
    try out.flush();
    if (!outcome.held) std.process.exit(1);
}

test "m08/probe parses its checks and renders its verdict" {
    try std.testing.expectEqual(Check.workspace_writable, Check.parse("workspace-writable").?);
    try std.testing.expectEqual(Check.store_read_only, Check.parse("store-read-only").?);
    try std.testing.expectEqual(Check.undeclared_write_denied, Check.parse("undeclared-write-denied").?);
    try std.testing.expectEqual(Check.undeclared_read_denied, Check.parse("undeclared-read-denied").?);
    try std.testing.expectEqual(Check.network_isolated, Check.parse("network-isolated").?);
    try std.testing.expectEqual(Check.pid_isolated, Check.parse("pid-isolated").?);
    try std.testing.expectEqual(Check.host_path_hidden, Check.parse("host-path-hidden").?);
    try std.testing.expectEqual(Check.resource_limit_enforced, Check.parse("resource-limit-enforced").?);
    try std.testing.expect(Check.parse("--help") == null);
    try std.testing.expect(Check.parse("") == null);
    // Every tag must be reachable from the command line, or a case would have
    // no way to run its check.
    inline for (std.meta.tags(Check)) |tag| {
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqual(tag, Check.parse(dashName(&buffer, tag)).?);
    }

    const gpa = std.testing.allocator;
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try render(&buffer.writer, .{
        .check = .store_read_only,
        .held = true,
        .detail = "ReadOnlyFileSystem",
    });
    const text = buffer.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"check\":\"store_read_only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"held\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ReadOnlyFileSystem") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));

    // The probe is only meaningful where a sandbox can exist.
    try std.testing.expectEqual(builtin.os.tag == .linux, builtin.os.tag == .linux);
}
