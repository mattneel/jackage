//! Real process identities for profile holders. Windows uses PID + FILETIME;
//! Linux uses PID + /proc start ticks. Never infer process identity from PID
//! alone. A process group bounds ordinary POSIX descendants, not a sandbox:
//! deliberately detached/group-escaping descendants are not prevented.
const std = @import("std");
const builtin = @import("builtin");
const windows = @import("../exec/windows.zig");
pub const Identity = windows.Identity;
pub const State = windows.State;

const Stat = struct { identity: Identity, group: u32, stopped: bool };

fn linuxStat(io: std.Io, _: std.mem.Allocator, pid: u32) !Stat {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/stat", .{pid});
    // procfs advertises st_size=0 despite returning data; stream into a fixed
    // buffer instead of a size-based convenience read (also avoids allocation
    // on every identity poll).
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    // An opened procfs process can disappear before read: Linux returns ESRCH,
    // which the pinned generic File read API treats as unexpected. Handle that
    // documented process-lifetime race explicitly, without logging/spurious
    // infrastructure failure or mistaking an unreadable process for a dead one.
    const count = while (true) {
        const rc = std.os.linux.read(file.handle, &buffer, buffer.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => break rc,
            .INTR => continue,
            .NOENT, .SRCH => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.ProcessStatUnreadable,
        }
    };
    if (count == 0) return error.FileNotFound;
    if (count == buffer.len) return error.ProcessStatTooLong;
    const bytes = buffer[0..count];
    // comm is parenthesized and may contain spaces or closing parentheses.
    const closer = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return error.ProcessIdentityUnavailable;
    var fields = std.mem.tokenizeAny(u8, bytes[closer + 1 ..], " \t\r\n");
    var group: u32 = 0;
    var created: u64 = 0;
    var stopped = false;
    for (0..20) |index| {
        const field = fields.next() orelse return error.ProcessIdentityUnavailable;
        if (index == 0) stopped = std.mem.eql(u8, field, "Z") or std.mem.eql(u8, field, "X");
        if (index == 2) group = try std.fmt.parseInt(u32, field, 10);
        if (index == 19) created = try std.fmt.parseInt(u64, field, 10);
    }
    return .{ .identity = .{ .pid = pid, .created = created }, .group = group, .stopped = stopped };
}

pub fn current(io: std.Io, gpa: std.mem.Allocator) !Identity {
    if (builtin.os.tag == .windows) return windows.identity(std.os.windows.GetCurrentProcess());
    if (builtin.os.tag == .linux) return forPid(io, gpa, @intCast(std.os.linux.getpid()));
    return error.ProfilePlatformUnavailable;
}

pub fn forPid(io: std.Io, gpa: std.mem.Allocator, pid: u32) !Identity {
    if (builtin.os.tag != .linux) return error.ProfilePlatformUnavailable;
    return (try linuxStat(io, gpa, pid)).identity;
}

pub fn state(io: std.Io, gpa: std.mem.Allocator, identity: Identity) State {
    if (builtin.os.tag == .windows) return windows.state(identity);
    if (builtin.os.tag != .linux) return .unknown;
    const stat = linuxStat(io, gpa, identity.pid) catch |err| return if (err == error.FileNotFound) .gone else .unknown;
    if (stat.identity.created != identity.created or stat.stopped) return .gone;
    return .live;
}

/// Lists live members of this execution's process group. Zombies no longer
/// hold executable mappings or writable workspaces. Unreadable /proc state is
/// an error, not permission to release the lease.
pub fn groupMembers(io: std.Io, gpa: std.mem.Allocator, group: u32) ![]Identity {
    if (builtin.os.tag != .linux) return error.ProfilePlatformUnavailable;
    const directory = try std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true });
    defer directory.close(io);
    var members: std.ArrayList(Identity) = .empty;
    errdefer members.deinit(gpa);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const stat = linuxStat(io, gpa, pid) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.group == group and !stat.stopped) try members.append(gpa, stat.identity);
    }
    return members.toOwnedSlice(gpa);
}

pub fn stopGroup(group: u32) !void {
    if (builtin.os.tag != .linux) return error.ProfilePlatformUnavailable;
    try std.posix.kill(-@as(std.posix.pid_t, @intCast(group)), .KILL);
}

pub fn stop(identity: Identity, io: std.Io, gpa: std.mem.Allocator) !void {
    if (state(io, gpa, identity) != .live) return;
    if (builtin.os.tag != .linux) return error.ProfilePlatformUnavailable;
    try std.posix.kill(@intCast(identity.pid), .KILL);
}
