//! Exact native binary launch with no shell or ambient executable lookup.
//!
//! Do not replace this adapter with the pinned std.process.spawn: even its
//! `.exe = .explicit` path calls windowsCreateProcessPathExt with ambient
//! PATHEXT (std/Io/Threaded.zig:16170-16206). At 16635-16650 and 16704-16714,
//! a .bat/.cmd match selects scriptCommandLine and cmdExePath, launching an
//! implicit cmd.exe. An absolute missing path can also select a PATHEXT suffix.
//!
//! CreateProcessW receives the exact lpApplicationName instead. Its command
//! line is only the Windows CRT argv wire encoding, never a shell command or
//! naive string join. Inherited handles are restricted to the three stdio
//! handles. Returned std.process.Child retains the pinned wait/kill lifecycle.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;

pub const Options = struct {
    program: []const u8,
    argv: []const []const u8,
    cwd: std.Io.Dir,
    environment: *const std.process.Environ.Map,
    capture: bool = true,
    suspended: bool = true,
};

extern "kernel32" fn CreatePipe(*w.HANDLE, *w.HANDLE, *w.SECURITY_ATTRIBUTES, u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn SetHandleInformation(w.HANDLE, u32, u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, *w.SECURITY_ATTRIBUTES, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetBinaryTypeW([*:0]const u16, *u32) callconv(.winapi) w.BOOL;
extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, u32, u32, *usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, u32, usize, *anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) w.BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;

const Pipe = struct { read: w.HANDLE, write: w.HANDLE };
const Startup = extern struct { info: w.STARTUPINFOW, attributes: *anyopaque };

fn security() w.SECURITY_ATTRIBUTES {
    return .{ .nLength = @sizeOf(w.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = .TRUE };
}

fn launchError() anyerror {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    return switch (GetLastError()) {
        2, 3 => error.FileNotFound,
        5 => error.AccessDenied,
        8, 14 => error.OutOfMemory,
        11, 193, 216 => error.InvalidExe,
        87 => error.InvalidArgument,
        206 => error.NameTooLong,
        else => error.NativeLaunchFailed,
    };
}

fn pipe() !Pipe {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    var attributes = security();
    var result: Pipe = undefined;
    if (CreatePipe(&result.read, &result.write, &attributes, 0) == .FALSE) return error.DiagnosticPipeUnavailable;
    errdefer w.CloseHandle(result.read);
    errdefer w.CloseHandle(result.write);
    if (SetHandleInformation(result.read, 1, 0) == .FALSE) return error.DiagnosticPipeUnavailable;
    return result;
}

/// Implements the same CRT quotation rules as the pinned std's native binary
/// argvToCommandLineWindows (17108-17187), not its batch-script encoder.
fn commandLine(gpa: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    if (argv.len == 0) return error.InvalidArg0;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    const first = argv[0];
    if (std.mem.indexOfAny(u8, first, "\"\x00") != null) return error.InvalidArg0;
    const quote_first = first.len == 0 or for (first) |byte| {
        if (byte <= ' ') break true;
    } else false;
    if (quote_first) try bytes.append(gpa, '"');
    try bytes.appendSlice(gpa, first);
    if (quote_first) try bytes.append(gpa, '"');
    for (argv[1..]) |argument| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArgument;
        try bytes.append(gpa, ' ');
        const quoted = argument.len == 0 or for (argument) |byte| {
            if (byte <= ' ' or byte == '"') break true;
        } else false;
        if (!quoted) {
            try bytes.appendSlice(gpa, argument);
            continue;
        }
        try bytes.append(gpa, '"');
        var slashes: usize = 0;
        for (argument) |byte| {
            switch (byte) {
                '\\' => slashes += 1,
                '"' => {
                    try bytes.appendNTimes(gpa, '\\', slashes * 2 + 1);
                    try bytes.append(gpa, '"');
                    slashes = 0;
                },
                else => {
                    try bytes.appendNTimes(gpa, '\\', slashes);
                    try bytes.append(gpa, byte);
                    slashes = 0;
                },
            }
        }
        try bytes.appendNTimes(gpa, '\\', slashes * 2);
        try bytes.append(gpa, '"');
    }
    const encoded = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, bytes.items);
    errdefer gpa.free(encoded);
    if (encoded.len >= 32767) return error.CommandLineTooLong;
    return encoded;
}

pub fn spawn(gpa: std.mem.Allocator, io: std.Io, options: Options) !std.process.Child {
    if (builtin.os.tag != .windows) return error.NativePlatformUnavailable;
    if (std.mem.indexOfScalar(u8, options.program, 0) != null) return error.InvalidArg0;
    const application = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, options.program);
    defer gpa.free(application);
    // CreateProcessW itself can dispatch batch scripts through a command
    // processor. A native image check is therefore mandatory even with an
    // explicit application name; 0/6 are native 32-/64-bit Windows images.
    // Win32 normalizes trailing dots/spaces, so they cannot disguise a
    // batch suffix and recover the implicit interpreter path.
    const basename = std.mem.trimEnd(u8, std.fs.path.basename(options.program), " .");
    const extension = std.fs.path.extension(basename);
    if (std.ascii.eqlIgnoreCase(extension, ".cmd") or std.ascii.eqlIgnoreCase(extension, ".bat")) return error.ShellScriptRequiresDeclaredInterpreter;
    var binary_type: u32 = 0;
    if (GetBinaryTypeW(application.ptr, &binary_type) == .FALSE) return launchError();
    if (binary_type != 0 and binary_type != 6) return error.NativeExecutableRequired;
    const arguments = try commandLine(gpa, options.argv);
    defer gpa.free(arguments);
    const directory = try options.cwd.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(directory);
    const directory_wide = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, directory);
    defer gpa.free(directory_wide);
    const environment = try options.environment.createWindowsBlock(gpa, .{});
    defer environment.deinit(gpa);

    var attributes = security();
    const input = CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), 0xc0000000, 7, &attributes, 3, 0x80, null);
    if (input == w.INVALID_HANDLE_VALUE) return error.NullDeviceUnavailable;
    defer w.CloseHandle(input);
    const out: ?Pipe = if (options.capture) try pipe() else null;
    errdefer if (out) |p| w.CloseHandle(p.read);
    defer if (out) |p| w.CloseHandle(p.write);
    const err: ?Pipe = if (options.capture) try pipe() else null;
    errdefer if (err) |p| w.CloseHandle(p.read);
    defer if (err) |p| w.CloseHandle(p.write);

    var list_bytes: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &list_bytes);
    if (list_bytes == 0) return error.ProcessAttributeSetupFailed;
    const list_storage = try gpa.alloc(usize, std.math.divCeil(usize, list_bytes, @sizeOf(usize)) catch return error.ProcessAttributeSetupFailed);
    defer gpa.free(list_storage);
    const list: *anyopaque = @ptrCast(list_storage.ptr);
    if (InitializeProcThreadAttributeList(list, 1, 0, &list_bytes) == .FALSE) return error.ProcessAttributeSetupFailed;
    defer DeleteProcThreadAttributeList(list);
    var handles = [_]w.HANDLE{ input, if (out) |p| p.write else input, if (err) |p| p.write else input };
    const handle_count: usize = if (options.capture) 3 else 1;
    if (UpdateProcThreadAttribute(list, 0, 0x00020002, @ptrCast(&handles), handle_count * @sizeOf(w.HANDLE), null, null) == .FALSE) return error.ProcessAttributeSetupFailed;
    var startup: Startup = .{ .info = std.mem.zeroes(w.STARTUPINFOW), .attributes = list };
    startup.info.cb = @sizeOf(Startup);
    startup.info.dwFlags = w.STARTF_USESTDHANDLES;
    startup.info.hStdInput = input;
    startup.info.hStdOutput = handles[1];
    startup.info.hStdError = handles[2];
    var process: w.PROCESS.INFORMATION = undefined;
    if (w.kernel32.CreateProcessW(application.ptr, arguments.ptr, null, null, .TRUE, .{
        .create_suspended = options.suspended,
        .create_no_window = true,
        .create_unicode_environment = true,
        .extended_startupinfo_present = true,
    }, environment.slice.ptr, directory_wide.ptr, &startup.info, &process) == .FALSE) {
        return launchError();
    }
    return .{
        .id = process.hProcess,
        .thread_handle = process.hThread,
        .stdin = null,
        .stdout = if (out) |p| .{ .handle = p.read, .flags = .{ .nonblocking = false } } else null,
        .stderr = if (err) |p| .{ .handle = p.read, .flags = .{ .nonblocking = false } } else null,
        .request_resource_usage_statistics = false,
    };
}
