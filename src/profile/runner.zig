//! Grammar: runner [--repo <url>] <package> [--] <args...>.
//! Only runner options before the package are interpreted. At most one leading
//! separator after the package is consumed; every remaining token is literal.
//! Quoting has already been handled by the caller's argv decoder, not a shell.
//!
//! prepareTransient/prepareCommand reserve a durable lease before copying the
//! closure into a unique workspace. Execution.run delegates actual launch,
//! exact argv, DWORD exit status and cleanup to M03's native Executor on
//! Windows and the POSIX process-group backend on Linux. Both use the lease ID
//! journal, so a crash never authorizes early lease release.
//! No installed profile or parent environment/PATH is modified. Child
//! environment is explicitly supplied, with no ambient fallback. Native
//! execution is not an isolation sandbox.
const std = @import("std");
const builtin = @import("builtin");
const posix = @import("posix.zig");
const artifact = @import("artifact.zig");
const profile = @import("manager.zig");
const digest = @import("../core/digest.zig");
const exec = @import("../exec/mod.zig");
const cancel = @import("../core/cancel.zig");

pub const Invocation = struct {
    repository: ?[]const u8,
    package: []const u8,
    arguments: []const []const u8,
};

pub fn parse(arguments: []const []const u8) !Invocation {
    var index: usize = 0;
    var repository: ?[]const u8 = null;
    if (arguments.len > 0 and std.mem.eql(u8, arguments[0], "--repo")) {
        if (arguments.len < 2 or arguments[1].len == 0) return error.RepositoryRequired;
        repository = arguments[1];
        index = 2;
    }
    if (index >= arguments.len) return error.PackageRequired;
    const package = arguments[index];
    if (package.len == 0 or package[0] == '-') return error.InvalidRunnerOption;
    index += 1;
    if (index < arguments.len and std.mem.eql(u8, arguments[index], "--")) index += 1;
    return .{ .repository = repository, .package = package, .arguments = arguments[index..] };
}

pub const RunOptions = struct {
    environment: []const exec.Environment = &.{},
    deadline_ns: ?u64 = null,
    log_budget: usize = 64 * 1024,
};
pub const Status = enum { program, launch_failure, infrastructure, canceled, timeout };
pub const Result = struct {
    status: Status,
    /// A program's full native status, including unsuccessful exits. Null for
    /// launch failure. It is never replaced by Jackage's action-failure code.
    program_status: ?u32,
    execution: exec.Result,
    workspace_retained: bool,
    /// CLI mapping: real program status unchanged; launch=127, infrastructure=7,
    /// cancellation=130, timeout=124. Structured status disambiguates a program
    /// that itself returns one of those values from a runner failure.
    pub fn callerStatus(self: Result) u32 {
        return switch (self.status) {
            .program => self.program_status orelse 7,
            .launch_failure => 127,
            .infrastructure => 7,
            .canceled => 130,
            .timeout => 124,
        };
    }
    pub fn deinit(self: *Result) void { self.execution.deinit(); self.* = undefined; }
};

pub const Execution = struct {
    manager: profile.Manager,
    lease: profile.Lease,
    /// Relative to Manager.root, unique per execution, never reused.
    workspace_path: []const u8,
    /// Absolute path of the copied entry point, not a store hardlink.
    program: []const u8,
    arguments: []const []const u8,
    workspace: std.Io.Dir,
    arena: std.heap.ArenaAllocator,
    directories_open: bool = true,
    has_run: bool = false,
    finished: bool = false,

    pub fn run(self: *Execution, options: RunOptions, token: *const cancel.Token) !Result {
        if (self.has_run) return error.ExecutionAlreadyRun;
        self.has_run = true;
        const journal_dir = try self.manager.root.openDir(self.manager.io, "profile-journal", .{ .iterate = true });
        defer journal_dir.close(self.manager.io);
        const journal: exec.Journal = .{ .dir = journal_dir, .io = self.manager.io, .gpa = self.manager.gpa };
        const request: exec.Request = .{
            .action_id = self.lease.id(),
            .program = self.program,
            .argv = self.arguments,
            .environment = options.environment,
            .workspace = self.workspace,
            .deadline_ns = options.deadline_ns,
            .log_budget = options.log_budget,
        };
        var native_result = if (builtin.os.tag == .windows)
            try (exec.Executor{ .io = self.manager.io, .gpa = self.manager.gpa, .store = self.manager.store, .journal = journal }).run(request, token)
        else
            try posix.run(self.manager.io, self.manager.gpa, journal, request, token);
        errdefer native_result.deinit();
        const retained = if (native_result.cleanup_complete) !(try self.finish()) else true;
        return .{
            .status = switch (native_result.status) {
                .success, .action_failure => .program,
                .launch_failure => .launch_failure,
                .cancelled => .canceled,
                .timeout => .timeout,
                .infrastructure => .infrastructure,
            },
            .program_status = if (native_result.status == .success or native_result.status == .action_failure) native_result.exit_code else null,
            .execution = native_result,
            .workspace_retained = retained,
        };
    }

    /// Never destroy a running or uncertain workspace. Busy/protected files
    /// leave both the workspace and its complete closure lease retained.
    pub fn finish(self: *Execution) !bool {
        if (self.finished) return true;
        try self.lease.ensureStopped();
        if (self.directories_open) { self.workspace.close(self.manager.io); self.directories_open = false; }
        self.manager.root.deleteTree(self.manager.io, self.workspace_path) catch |err| switch (err) {
            error.FileBusy, error.AccessDenied, error.PermissionDenied => return false,
            else => return err,
        };
        try self.lease.release();
        self.finished = true;
        return true;
    }

    /// Frees local resources. If cleanup is uncertain, disk ownership remains
    /// durable for a restarted controller; deinit does not claim it is gone.
    pub fn deinit(self: *Execution) void {
        if (!self.finished) _ = self.finish() catch false;
        if (self.directories_open) self.workspace.close(self.manager.io);
        self.lease.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn prepareTransient(manager: profile.Manager, object: digest.Digest, command_name: ?[]const u8, arguments: []const []const u8) !Execution {
    var lease = try manager.acquireLease("_transient", null, &.{object}, null);
    errdefer { lease.release() catch {}; lease.deinit(); }
    const parsed = try artifact.read(manager.store, manager.gpa, object);
    defer parsed.deinit();
    const name = command_name orelse parsed.value.default_command orelse return error.DefaultCommandMissing;
    const command = artifact.commandNamed(parsed.value, name) orelse return error.CommandNotFound;
    return prepare(manager, lease, &.{object}, object, command, arguments);
}

pub fn prepareCommand(manager: profile.Manager, profile_name: []const u8, command_name: []const u8, arguments: []const []const u8) !Execution {
    var selected = try manager.leaseActive(profile_name);
    defer selected.generation.deinit();
    errdefer { selected.lease.release() catch {}; selected.lease.deinit(); }
    const command = selected.generation.command(command_name) orelse return error.CommandNotFound;
    const roots = try manager.gpa.alloc(digest.Digest, selected.generation.manifest().packages.len);
    defer manager.gpa.free(roots);
    for (selected.generation.manifest().packages, roots) |package, *root| root.* = try digest.Digest.parse(package.artifact);
    return prepare(manager, selected.lease, roots, try digest.Digest.parse(command.artifact), .{ .name = command.name, .path = command.path, .arguments = command.arguments }, arguments);
}

fn prepare(manager: profile.Manager, lease: profile.Lease, roots: []const digest.Digest, object: digest.Digest, command: artifact.Command, arguments: []const []const u8) !Execution {
    var arena = std.heap.ArenaAllocator.init(manager.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try a.print("profile-workspaces/{s}", .{lease.id()});
    // Atomic directory creation refuses an existing writable workspace.
    try manager.root.createDir(manager.io, path, .default_dir);
    errdefer manager.root.deleteTree(manager.io, path) catch {};
    const workspace_root = try manager.root.openDir(manager.io, path, .{});
    defer workspace_root.close(manager.io);
    try artifact.materialize(manager.store, workspace_root, roots);
    var package_buffer: [80]u8 = undefined;
    const package_path = try artifact.packagePath(object, &package_buffer);
    const package_dir = try workspace_root.openDir(manager.io, package_path, .{ .iterate = true });
    errdefer package_dir.close(manager.io);
    const program = try package_dir.realPathFileAlloc(manager.io, command.path, a);
    const argv = try a.alloc([]const u8, command.arguments.len + arguments.len);
    for (command.arguments, 0..) |argument, index| argv[index] = try a.dupe(u8, argument);
    for (arguments, 0..) |argument, index| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArgument;
        argv[command.arguments.len + index] = try a.dupe(u8, argument);
    }
    return .{ .manager = manager, .lease = lease, .workspace_path = path, .program = program, .arguments = argv, .workspace = package_dir, .arena = arena };
}

pub fn runTransient(manager: profile.Manager, object: digest.Digest, arguments: []const []const u8, options: RunOptions, token: *const cancel.Token) !Result {
    var execution = try prepareTransient(manager, object, null, arguments);
    defer execution.deinit();
    return execution.run(options, token);
}
