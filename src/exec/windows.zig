//! Native Windows process identity and best-effort tree ownership.
//!
//! PID plus creation time prevents a recycled PID from being treated as our
//! process. taskkill /T /F is not a job object: detached/reparented processes
//! and the snapshot/spawn race are not an enforced isolation boundary.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
pub const spawnExact = @import("windows_spawn.zig").spawn;

pub const Identity = struct {
    pid: u32,
    created: u64,
};

pub const State = enum { live, gone, unknown };

extern "kernel32" fn GetProcessId(w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetProcessTimes(w.HANDLE, *w.FILETIME, *w.FILETIME, *w.FILETIME, *w.FILETIME) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetExitCodeProcess(w.HANDLE, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(u32, w.BOOL, u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn ResumeThread(w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn SetEnvironmentVariableW([*:0]const u16, ?[*:0]const u16) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetWindowsDirectoryW([*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn CreateToolhelp32Snapshot(u32, u32) callconv(.winapi) w.HANDLE;
extern "kernel32" fn Process32FirstW(w.HANDLE, *ProcessEntry) callconv(.winapi) w.BOOL;
extern "kernel32" fn Process32NextW(w.HANDLE, *ProcessEntry) callconv(.winapi) w.BOOL;

const ProcessEntry = extern struct {
    size: u32 = @sizeOf(ProcessEntry),
    usage: u32 = 0,
    pid: u32 = 0,
    default_heap: usize = 0,
    module: u32 = 0,
    threads: u32 = 0,
    parent_pid: u32 = 0,
    priority: i32 = 0,
    flags: u32 = 0,
    executable: [260]u16 = @splat(0),
};

pub fn identity(handle: w.HANDLE) !Identity {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    const pid = GetProcessId(handle);
    if (pid == 0) return error.ProcessIdentityUnavailable;
    var creation: w.FILETIME = undefined;
    var exit: w.FILETIME = undefined;
    var kernel: w.FILETIME = undefined;
    var user: w.FILETIME = undefined;
    if (GetProcessTimes(handle, &creation, &exit, &kernel, &user) == .FALSE) return error.ProcessIdentityUnavailable;
    return .{ .pid = pid, .created = (@as(u64, creation.dwHighDateTime) << 32) | creation.dwLowDateTime };
}

pub fn state(process: Identity) State {
    if (builtin.os.tag != .windows) return .unknown;
    const handle = OpenProcess(0x00100000 | 0x1000, .FALSE, process.pid) orelse {
        return if (GetLastError() == 87) .gone else .unknown;
    };
    defer w.CloseHandle(handle);
    const actual = identity(handle) catch return .unknown;
    if (actual.created != process.created) return .gone;
    return switch (WaitForSingleObject(handle, 0)) {
        0 => .gone,
        258 => .live,
        else => .unknown,
    };
}

pub fn isFinished(handle: w.HANDLE) !bool {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    return switch (WaitForSingleObject(handle, 0)) {
        0 => true,
        258 => false,
        else => error.ProcessStateUnavailable,
    };
}

pub fn exitCode(handle: w.HANDLE) !u32 {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    if (!try isFinished(handle)) return error.ProcessStillRunning;
    var code: u32 = 0;
    if (GetExitCodeProcess(handle, &code) == .FALSE) return error.ProcessStateUnavailable;
    return code;
}

pub fn resumeProcess(thread: w.HANDLE) !void {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    if (ResumeThread(thread) == std.math.maxInt(u32)) return error.ProcessResumeFailed;
}

/// Uses the system directory from the PEB, not an ambient PATH search.
pub fn systemTool(gpa: std.mem.Allocator, basename: []const u8) ![]u8 {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    const directory = try std.unicode.wtf16LeToWtf8Alloc(gpa, w.getSystemDirectoryWtf16Le());
    defer gpa.free(directory);
    return std.fs.path.join(gpa, &.{ directory, basename });
}

pub fn discoverDescendants(gpa: std.mem.Allocator, root: Identity) ![]Identity {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    const snapshot = CreateToolhelp32Snapshot(2, 0);
    if (snapshot == w.INVALID_HANDLE_VALUE) return error.ProcessSnapshotUnavailable;
    defer w.CloseHandle(snapshot);
    var entries: std.ArrayList(ProcessEntry) = .empty;
    defer entries.deinit(gpa);
    var entry: ProcessEntry = .{};
    if (Process32FirstW(snapshot, &entry) == .FALSE) return error.ProcessSnapshotUnavailable;
    while (true) {
        try entries.append(gpa, entry);
        if (Process32NextW(snapshot, &entry) == .FALSE) {
            if (GetLastError() != 18) return error.ProcessSnapshotUnavailable;
            break;
        }
    }
    var family: std.ArrayList(Identity) = .empty;
    errdefer family.deinit(gpa);
    try family.append(gpa, root);
    var cursor: usize = 0;
    while (cursor < family.items.len) : (cursor += 1) {
        for (entries.items) |candidate| {
            if (candidate.parent_pid != family.items[cursor].pid) continue;
            var already_owned = false;
            for (family.items) |owned| {
                if (owned.pid == candidate.pid) already_owned = true;
            }
            if (already_owned) continue;
            const handle = OpenProcess(0x00100000 | 0x1000, .FALSE, candidate.pid) orelse {
                if (GetLastError() == 87) continue;
                return error.ProcessIdentityUnavailable;
            };
            defer w.CloseHandle(handle);
            const found = try identity(handle);
            // PID-only parent links can outlive a parent. A process older than
            // its claimed parent cannot be one of this action's descendants.
            if (found.created < family.items[cursor].created) continue;
            try family.append(gpa, found);
        }
    }
    if (family.items.len > 0) _ = family.orderedRemove(0);
    return family.toOwnedSlice(gpa);
}

/// Waits for taskkill itself and checks identity before addressing a PID.
pub fn taskkill(gpa: std.mem.Allocator, io: std.Io, process: Identity) !void {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    switch (state(process)) {
        .gone => return,
        .unknown => return error.ProcessStateUnavailable,
        .live => {},
    }
    const program = try systemTool(gpa, "taskkill.exe");
    defer gpa.free(program);
    var pid_buffer: [16]u8 = undefined;
    const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{process.pid});
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    // Controller utility minimum comes from Windows itself, never ambient
    // variables. This does not add anything to the action's declared map.
    var root_buffer: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const root_length = GetWindowsDirectoryW(&root_buffer, root_buffer.len);
    if (root_length == 0 or root_length >= root_buffer.len) return error.WindowsDirectoryUnavailable;
    const system_root = try std.unicode.wtf16LeToWtf8Alloc(gpa, root_buffer[0..root_length]);
    defer gpa.free(system_root);
    try env.put("SystemRoot", system_root);
    var child = try spawnExact(gpa, io, .{
        .program = program,
        .argv = &.{ program, "/PID", pid, "/T", "/F" },
        .cwd = .cwd(),
        .environment = &env,
        .capture = false,
        .suspended = false,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    if (!term.success() and state(process) != .gone) return error.ProcessTreeCleanupFailed;
}

/// Reject every path component, not only a final symlink. GetFileAttributesW
/// sees all reparse tags (including junctions), unlike a symlink-only stat.
pub fn rejectReparse(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !void {
    if (builtin.os.tag != .windows) return;
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try dir.realPath(io, &root_buffer);
    var components = std.mem.splitScalar(u8, sub_path, '/');
    var prefix_length: usize = 0;
    while (components.next()) |component| {
        if (prefix_length != 0) prefix_length += 1;
        prefix_length += component.len;
        if (prefix_length > sub_path.len) return error.OutputEscape;
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const absolute = try std.fmt.bufPrint(&path_buffer, "{s}\\{s}", .{ root_buffer[0..root_length], sub_path[0..prefix_length] });
        var wide: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
        const length = try w.wtf8ToWtf16Le(wide[0 .. wide.len - 1], absolute);
        wide[length] = 0;
        const attributes = GetFileAttributesW(wide[0..length :0]);
        if (attributes == w.INVALID_FILE_ATTRIBUTES) return error.OutputUnavailable;
        if (attributes & 0x400 != 0) return error.OutputEscape;
    }
}

/// Tests use a real parent-only sentinel, then restore the process environment.
pub fn setEnvironment(name: [:0]const u16, value: ?[:0]const u16) !void {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    if (SetEnvironmentVariableW(name.ptr, if (value) |v| v.ptr else null) == .FALSE) return error.EnvironmentUpdateFailed;
}

extern "kernel32" fn PeekNamedPipe(w.HANDLE, ?*anyopaque, u32, ?*u32, *u32, ?*u32) callconv(.winapi) w.BOOL;

/// Nonblocking availability lets bounded drainers finish even if a process
/// outside the supported ownership boundary has inherited a pipe handle.
pub fn pipeAvailable(file: std.Io.File) !?u32 {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    var available: u32 = 0;
    if (PeekNamedPipe(file.handle, null, 0, null, &available, null) == .FALSE) {
        if (GetLastError() == 109) return null;
        return error.DiagnosticReadFailed;
    }
    return available;
}
