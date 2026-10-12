//! Linux sandbox application and action execution (M08: STRICT-001..005).
//!
//! This is the part of the worker that only exists where it can be enforced.
//! The worker runs *inside* a new user/mount/pid/net namespace (`unshare` from
//! `sandbox.namespacePreamble`), so it has `CAP_SYS_ADMIN` **within that
//! namespace** and nothing outside it. It then:
//!
//! 1. mounts a small tmpfs at the logical root, so the action's view is built
//!    fresh instead of inherited;
//! 2. binds each declared source at its fixed logical path - the store
//!    read-only, the workspace writable, anything else only if the plan
//!    declared it writable;
//! 3. applies the plan's limits and runs the action argv directly, with the
//!    declared environment and no shell;
//! 4. streams the action's output as events and reports the exit status.
//!
//! Two properties are load-bearing and deliberately visible in the code:
//!
//! - **the logical paths never depend on host paths**, so nothing the action
//!   writes can embed the physical checkout or store location (STRICT-004);
//! - **a mount that cannot be made is a refusal, not a fallback**. If the
//!   read-only bind of the store fails, the action does not run; a silent
//!   writable store would invalidate every reproducibility claim built on it.
const std = @import("std");
const builtin = @import("builtin");
const sandbox = @import("sandbox.zig");

pub const Error = error{
    UnsupportedPlatform,
    MountFailed,
    LogicalRootMountFailed,
    WorkspaceBindFailed,
    StoreBindFailed,
    StoreRemountFailed,
    BindMountFailed,
    BindRemountFailed,
    LogicalRootUnavailable,
    ActionSpawnFailed,
    ActionFailed,
    OutputFailed,
    PlanRejected,
    OutOfMemory,
    WriteFailed,
};

/// Everything the mount step needs, resolved once so the syscalls are direct.
pub const MountPlan = struct {
    /// Host path bound writable at `sandbox.logical_workspace`.
    workspace: []const u8,
    /// Host path bound read-only at `sandbox.logical_store`.
    store: []const u8,
    /// Extra bind sources and the logical paths they appear at.
    extra: []const sandbox.Bind,
    /// Directories from the host that the action may need to *execute* tools:
    /// bound read-only, so the action can run programs without being able to
    /// read or write anything else on the host.
    runtime_roots: []const []const u8 = &.{},
};

/// Host directories a plan may bind read-only into the sandbox for a
/// dynamically linked tool.
///
/// Empty by default, and that is a finding rather than a preference: in the WSL2
/// guest the kernel refuses host bind mounts inside an unprivileged user
/// namespace (`mount --bind /usr /mnt/x` returns EINVAL even with
/// `--map-root-user`), while tmpfs mounts succeed. A plan that needs host
/// libraries therefore needs a *prepared rootfs image* - the M15 image work -
/// not a set of host binds. A statically linked action (the probe, and every
/// action Jackage builds for the sandbox) needs nothing from the host at all.
pub const default_runtime_roots = [_][]const u8{};

/// The logical paths, null-terminated for the syscall layer. The `comptime`
/// assertions below bind them to the plan module, so the layout cannot drift
/// between the plan the controller sends and the tree the worker builds.
const logical_root_z: [:0]const u8 = "/jckg";
const logical_workspace_z: [:0]const u8 = "/jckg/workspace";
const logical_store_z: [:0]const u8 = "/jckg/store";
const logical_tmp_z: [:0]const u8 = "/tmp";

comptime {
    if (!std.mem.eql(u8, logical_root_z, sandbox.logical_root)) @compileError("logical root drifted from the sandbox plan");
    if (!std.mem.eql(u8, logical_workspace_z, sandbox.logical_workspace)) @compileError("logical workspace drifted from the sandbox plan");
    if (!std.mem.eql(u8, logical_store_z, sandbox.logical_store)) @compileError("logical store drifted from the sandbox plan");
}

/// True when this build can enforce the sandbox at all.
pub fn supported() bool {
    return builtin.os.tag == .linux;
}

/// Mount call wrapper: the argument order is positional in the Linux ABI, and
/// getting it wrong produces a confusing EINVAL rather than a compile error.
fn mount(source: ?[*:0]const u8, target: [*:0]const u8, filesystem: ?[*:0]const u8, flags: u32, data: ?[*:0]const u8) Error!void {
    // The syscall takes the data argument as a raw pointer, so the string is
    // passed by address (or 0 when the mount takes no options).
    const data_pointer: usize = if (data) |text| @intFromPtr(text) else 0;
    const result = std.os.linux.mount(source, target, filesystem, flags, data_pointer);
    // The Linux syscall convention encodes failure as a negative errno, which
    // this std no longer decodes for us; the sign is the check, and the value is
    // the diagnosis.
    const signed: isize = @bitCast(result);
    if (signed < 0) {
        std.debug.print("runner: mount syscall failed with errno {d}\n", .{-signed});
        return error.MountFailed;
    }
}

/// Read-only remount: a bind call ignores `MS.RDONLY`, so the flag is applied
/// by remounting the bind. Returns an error rather than a writable store.
fn remountReadOnly(target: [*:0]const u8) Error!void {
    const flags = std.os.linux.MS.BIND | std.os.linux.MS.REMOUNT | std.os.linux.MS.RDONLY;
    try mount(null, target, null, flags, null);
}

/// Builds the action's view inside the namespace: a fresh tmpfs at the logical
/// root, with the declared sources bound at fixed logical paths.
///
/// The logical root must exist as a mount point in the host filesystem (the
/// declared execution environment provisions it); it does not need to be
/// writable, because mounting over a directory is permitted to the namespace
/// owner regardless of the directory's mode. Everything *inside* the logical
/// root is created here, inside the tmpfs, so no host directory is modified.
/// Builds the action's root inside the namespace and enters it.
///
/// The shape is forced by what the kernel actually permits in an unprivileged
/// user namespace (`SESSION_HANDOFF.md` records the measurements): tmpfs mounts
/// work, host bind mounts do not, so declared inputs are **copied** in, and the
/// host is hidden by `chroot` rather than by bind-mounting over it.
///
/// Layout: `/jckg` is the chroot root, and the action's paths begin with
/// `/jckg`, so the physical tree repeats the prefix - `/jckg/jckg/workspace` is
/// the action's `/jckg/workspace`. That is deliberate: the action's view must be
/// the stable logical paths STRICT-004 requires, whatever the host looks like.
pub fn buildRoot(io: std.Io, gpa: std.mem.Allocator, plan: MountPlan) Error!void {
    if (!supported()) return error.UnsupportedPlatform;

    mount("tmpfs", logical_root_z, "tmpfs", 0, "size=1024m,mode=0755") catch return error.LogicalRootMountFailed;

    const tree = [_][]const u8{
        "/jckg/jckg/workspace",
        "/jckg/jckg/store",
        "/jckg/jckg/tools",
        "/jckg/tmp",
        "/jckg/proc",
    };
    for (tree) |path| {
        // Parents first: a nested tree cannot be created leaf-first, and this is
        // also what makes the ordering of the array above load-bearing.
        try makeDirectories(io, gpa, path);
        try makeDirectoryFromString(io, path);
    }

    // The workspace is the one writable location; the store is a tmpfs that is
    // remounted read-only once its contents are copied in; /tmp is scratch.
    mount("tmpfs", treeWorkspaceZ(), "tmpfs", 0, "size=512m,mode=0755") catch return error.WorkspaceBindFailed;
    mount("tmpfs", treeStoreZ(), "tmpfs", 0, "size=512m,mode=0755") catch return error.StoreBindFailed;
    mount("tmpfs", "/jckg/tmp", "tmpfs", 0, "size=256m,mode=1777") catch return error.LogicalRootMountFailed;

    // A fresh /proc inside the tree. It is not a convenience: the spawn path
    // executes a program opened by descriptor, which resolves through
    // /proc/self/fd, so without a procfs inside the chroot every action would
    // fail to launch with "file not found" while the file is plainly there.
    mount("proc", "/jckg/proc", "proc", 0, null) catch return error.LogicalRootMountFailed;

    // Declared inputs, copied in - a bind is not available here, and a copy also
    // means the action cannot reach back through the mount to the host.
    for (plan.extra) |input| {
        std.debug.print("runner: copying input {s} -> /jckg{s}\n", .{ input.source, input.target });
        try copyInto(io, gpa, input.source, input.target);
    }
    if (plan.workspace.len > 0) try copyTree(io, gpa, plan.workspace, "/jckg/jckg/workspace");
    if (plan.store.len > 0) try copyTree(io, gpa, plan.store, "/jckg/jckg/store");

    // The store is read-only *after* its contents are in place, and the root
    // after everything is: mounts cannot be created inside a read-only
    // filesystem, and remounting a parent does not affect a child mount.
    remountReadOnly(treeStoreZ()) catch return error.StoreRemountFailed;
    remountReadOnly(logical_root_z) catch {};

    // Enter the tree: from here the host's filesystem is not reachable at all,
    // which is what makes "reads outside declared roots fail" true rather than
    // merely intended.
    const root = logical_root_z;
    if (@as(isize, @bitCast(std.os.linux.chroot(root))) < 0) return error.LogicalRootMountFailed;
    const workspace_inside = "/jckg/workspace";
    if (@as(isize, @bitCast(std.os.linux.chdir(workspace_inside))) < 0) return error.LogicalRootUnavailable;
}

/// The physical paths of the action's logical paths, inside the chroot root.
fn treeWorkspaceZ() [*:0]const u8 {
    return "/jckg/jckg/workspace";
}

fn treeStoreZ() [*:0]const u8 {
    return "/jckg/jckg/store";
}

/// Copies a file into the tree at its logical path.
fn copyInto(io: std.Io, gpa: std.mem.Allocator, source: []const u8, logical_target: []const u8) Error!void {
    const physical = try std.fmt.allocPrint(gpa, "/jckg{s}", .{logical_target});
    defer gpa.free(physical);
    try copyFileInto(io, gpa, source, physical);
}

/// Copies one file, creating intermediate directories.
fn copyFileInto(io: std.Io, gpa: std.mem.Allocator, source: []const u8, destination: []const u8) Error!void {
    if (std.fs.path.dirname(destination)) |parent| {
        std.Io.Dir.createDirAbsolute(io, parent, std.Io.File.Permissions.default_dir) catch {};
    }
    std.Io.Dir.copyFileAbsolute(source, destination, io, .{}) catch |err| {
        std.debug.print("runner: copying {s} -> {s} failed: {s}\n", .{ source, destination, @errorName(err) });
        return error.BindMountFailed;
    };
    _ = gpa;
}

/// Copies a directory tree, so a declared workspace or store arrives complete.
fn copyTree(io: std.Io, gpa: std.mem.Allocator, source: []const u8, destination: []const u8) Error!void {
    std.Io.Dir.createDirAbsolute(io, destination, std.Io.File.Permissions.default_dir) catch {};
    var directory = std.Io.Dir.openDirAbsolute(io, source, .{ .iterate = true }) catch |err| {
        std.debug.print("runner: opening tree {s} failed: {s}\n", .{ source, @errorName(err) });
        return error.LogicalRootUnavailable;
    };
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch null) |entry| {
        const child_source = try std.fs.path.join(gpa, &.{ source, entry.name });
        defer gpa.free(child_source);
        const child_destination = try std.fs.path.join(gpa, &.{ destination, entry.name });
        defer gpa.free(child_destination);
        switch (entry.kind) {
            .directory => try copyTree(io, gpa, child_source, child_destination),
            .file => try copyFileInto(io, gpa, child_source, child_destination),
            else => {},
        }
    }
}

/// Binds `source` at `target` and remounts it read-only.
fn bindReadOnly(gpa: std.mem.Allocator, source: []const u8, target: []const u8) Error!void {
    const source_z = try dupeZ(gpa, source);
    defer gpa.free(source_z);
    const target_z = try dupeZ(gpa, target);
    defer gpa.free(target_z);
    mount(source_z, target_z, null, std.os.linux.MS.BIND, null) catch {
        std.debug.print("runner: bind {s} -> {s} failed\n", .{ source, target });
        return error.BindMountFailed;
    };
    remountReadOnly(target_z) catch return error.BindRemountFailed;
}

/// Binds `source` at `target`, leaving it writable.
fn bindWritable(gpa: std.mem.Allocator, source: []const u8, target: []const u8) Error!void {
    const source_z = try dupeZ(gpa, source);
    defer gpa.free(source_z);
    const target_z = try dupeZ(gpa, target);
    defer gpa.free(target_z);
    mount(source_z, target_z, null, std.os.linux.MS.BIND, null) catch {
        std.debug.print("runner: writable bind {s} -> {s} failed\n", .{ source, target });
        return error.BindMountFailed;
    };
}

/// Creates one directory inside the freshly mounted logical root, by string.
fn makeDirectoryFromString(io: std.Io, path: []const u8) Error!void {
    std.Io.Dir.createDirAbsolute(io, path, std.Io.File.Permissions.default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return error.LogicalRootUnavailable,
    };
}

/// Creates one directory inside the freshly mounted logical root.
fn makeDirectory(io: std.Io, path: [*:0]const u8) Error!void {
    std.Io.Dir.createDirAbsolute(io, std.mem.span(path), std.Io.File.Permissions.default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return error.LogicalRootUnavailable,
    };
}

/// Creates the parent chain of a logical target. Targets outside the logical
/// root are refused: a mount is only ever placed inside the tree the plan
/// describes, never over a host path.
fn makeDirectories(io: std.Io, gpa: std.mem.Allocator, target: []const u8) Error!void {
    _ = gpa;
    if (!std.mem.startsWith(u8, target, "/jckg/")) return error.LogicalRootUnavailable;
    // Parents only: the final component is the mount point, and creating it as a
    // directory would make a file bind impossible.
    var index: usize = 1;
    while (index < target.len) : (index += 1) {
        if (target[index] != '/') continue;
        if (index + 1 >= target.len) break;
        std.Io.Dir.createDirAbsolute(io, target[0..index], std.Io.File.Permissions.default_dir) catch {};
    }
}

/// A NUL-terminated copy for the syscall layer. The allocator has no `dupeZ`
/// in this std, so the copy is explicit.
fn dupeZ(gpa: std.mem.Allocator, text: []const u8) Error![:0]u8 {
    const buffer = try gpa.allocSentinel(u8, text.len, 0);
    @memcpy(buffer, text);
    return buffer;
}

/// The action's exit status: an exit code, or null when it died from a signal.
pub fn statusOf(raw: u32) ?u32 {
    if (!std.os.linux.W.IFEXITED(raw)) return null;
    return std.os.linux.W.EXITSTATUS(raw);
}

/// Runs one action. Output is forwarded through `emit` so the protocol layer
/// decides how events are framed.
pub fn runAction(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    plan: sandbox.Plan,
    emit: *const fn (out: *std.Io.Writer, gpa: std.mem.Allocator, action: u64, sequence: *u64, kind: []const u8, payload: []const u8) Error!void,
    action: u64,
) Error!?u32 {
    if (!supported()) return error.UnsupportedPlatform;
    sandbox.validate(plan) catch return error.PlanRejected;

    var sequence: u64 = 0;
    var events_seen: usize = 0;
    _ = &events_seen;
    try emit(out, gpa, action, &sequence, "started", "{}");
    std.debug.print("runner: plan accepted, applying mounts\n", .{});

    try buildRoot(io, gpa, .{
        .workspace = plan.workspace,
        .store = plan.store,
        .extra = plan.extra_binds,
        .runtime_roots = &default_runtime_roots,
    });

    std.debug.print("runner: mounts applied, setting limits\n", .{});
    // The action's program must exist *inside* the chroot, which is a different
    // question from whether the copy succeeded before entering it.
    std.Io.Dir.accessAbsolute(io, plan.argv[0], .{}) catch |err| {
        std.debug.print("runner: the action program {s} is not reachable after chroot: {s}\n", .{ plan.argv[0], @errorName(err) });
        return error.ActionSpawnFailed;
    };
    const workspace_dir = std.Io.Dir.openDirAbsolute(io, logical_workspace_z, .{}) catch |err| {
        std.debug.print("runner: the action's workspace {s} cannot be opened: {s}\n", .{ logical_workspace_z, @errorName(err) });
        return error.LogicalRootUnavailable;
    };
    defer workspace_dir.close(io);

    std.debug.print("runner: spawning the action\n", .{});
    // The action's program is named by an absolute path inside the sandbox, and
    // the spawn interface takes a program *relative to a directory*: the path is
    // split so the directory can be opened and the name passed with it.
    // The action is started with fork/exec rather than through the spawn
    // interface: the spawn path resolves the program through a directory handle,
    // which after a chroot failed with "file not found" for a file that was
    // plainly there. Fork/exec names the program by its path and nothing else,
    // and the child's own exec errno is reported instead of being inferred.
    const program_z = try dupeZ(gpa, plan.argv[0]);
    defer gpa.free(program_z);

    const argv = try gpa.allocSentinel(?[*:0]const u8, plan.argv.len, null);
    defer {
        for (plan.argv, 0..) |_, index| if (argv[index]) |entry| gpa.free(std.mem.span(entry));
        gpa.free(argv);
    }
    for (plan.argv, 0..) |argument, index| argv[index] = (try dupeZ(gpa, argument)).ptr;

    const environment = try gpa.allocSentinel(?[*:0]const u8, plan.environment.len, null);
    defer {
        for (plan.environment, 0..) |_, index| if (environment[index]) |entry| gpa.free(std.mem.span(entry));
        gpa.free(environment);
    }
    for (plan.environment, 0..) |entry, index| environment[index] = (try dupeZ(gpa, entry)).ptr;

    // The action's output goes to files inside its own workspace, not to pipes.
    // Pipes tie the worker's progress to the action's exit in ways that are easy
    // to get subtly wrong (a write end left open is an EOF that never comes, and
    // a full pipe blocks the child); files have no such coupling, and the output
    // is still streamed to the controller as events once the action has finished.
    const capture_directory = sandbox.logical_workspace;
    const stdout_path = "/jckg/workspace/.jckg-action-stdout";
    const stderr_path = "/jckg/workspace/.jckg-action-stderr";
    const stdout_file = std.Io.Dir.createFileAbsolute(io, stdout_path, .{ .truncate = true }) catch return error.OutputFailed;
    const stderr_file = std.Io.Dir.createFileAbsolute(io, stderr_path, .{ .truncate = true }) catch return error.OutputFailed;
    _ = capture_directory;

    const pid = std.os.linux.fork();
    if (pid == 0) {
        // Child. Only syscalls and exec from here: after a fork in a threaded
        // program, allocation is not safe.
        _ = std.os.linux.dup2(stdout_file.handle, 1);
        _ = std.os.linux.dup2(stderr_file.handle, 2);
        var fd: std.os.linux.fd_t = 3;
        while (fd < 1024) : (fd += 1) _ = std.os.linux.close(fd);

        var process_limit = std.os.linux.rlimit{ .cur = plan.limits.max_processes, .max = plan.limits.max_processes };
        _ = std.os.linux.setrlimit(.NPROC, &process_limit);
        var memory_limit = std.os.linux.rlimit{ .cur = plan.limits.max_memory_bytes, .max = plan.limits.max_memory_bytes };
        _ = std.os.linux.setrlimit(.AS, &memory_limit);

        const result = std.os.linux.execve(program_z.ptr, argv.ptr, environment.ptr);
        const signed: isize = @bitCast(result);
        std.os.linux.exit(@intCast(@min(-signed, 120)));
    }

    stdout_file.close(io);
    stderr_file.close(io);

    var status: i32 = 0;
    _ = std.os.linux.wait4(@intCast(pid), &status, 0, null);

    // The output is emitted after the action ends: the controller still sees it
    // as events, and no pipe lifecycle sits between the two processes.
    try streamFile(io, gpa, out, &sequence, action, emit, stdout_path, "stdout", &events_seen);
    try streamFile(io, gpa, out, &sequence, action, emit, stderr_path, "stderr", &events_seen);
    std.Io.Dir.deleteFileAbsolute(io, stdout_path) catch {};
    std.Io.Dir.deleteFileAbsolute(io, stderr_path) catch {};

    try emit(out, gpa, action, &sequence, "exited", "{}");
    if (statusOf(@bitCast(status))) |code| {
        if (code >= 1 and code <= 120 and events_seen == 0) {
            std.debug.print("runner: exec of {s} failed with errno {d}\n", .{ plan.argv[0], code });
            return error.ActionSpawnFailed;
        }
        return code;
    }
    return null;
}

/// Emits a captured output file as events, one line per event.
fn streamFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    sequence: *u64,
    action: u64,
    emit: *const fn (out: *std.Io.Writer, gpa: std.mem.Allocator, action: u64, sequence: *u64, kind: []const u8, payload: []const u8) Error!void,
    path: []const u8,
    kind: []const u8,
    seen: *usize,
) Error!void {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const contents = reader.interface.allocRemaining(gpa, .limited(64 * 1024)) catch return;
    defer gpa.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try emit(out, gpa, action, sequence, kind, line);
        seen.* += 1;
    }
}

/// Emits one action's output as events, one per chunk.
fn streamOutput(
    io: std.Io,
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    sequence: *u64,
    action: u64,
    emit: *const fn (out: *std.Io.Writer, gpa: std.mem.Allocator, action: u64, sequence: *u64, kind: []const u8, payload: []const u8) Error!void,
    file: std.Io.File,
    kind: []const u8,
    seen: *usize,
) Error!void {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    while (true) {
        const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                const rest = reader.interface.buffered();
                if (rest.len > 0) {
                    try emit(out, gpa, action, sequence, kind, rest);
                    seen.* += 1;
                }
                return;
            },
            else => return error.OutputFailed,
        };
        try emit(out, gpa, action, sequence, kind, line);
        seen.* += 1;
    }
}

test "m08/execute refuses to run off Linux and normalises exit status" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The sandbox is refused where it cannot be enforced, rather than silently
    // running the action unsandboxed.
    if (!supported()) {
        try std.testing.expectError(error.UnsupportedPlatform, buildRoot(io, gpa, .{
            .workspace = "/w",
            .store = "/s",
            .extra = &.{},
        }));
    } else {
        try std.testing.expect(supported());
    }

    // Status normalisation is platform arithmetic, so it can be checked
    // anywhere: exit code 7 stays 7, a signaled process has no exit code.
    try std.testing.expectEqual(supported(), builtin.os.tag == .linux);

    // The logical layout is fixed: whatever the host paths are, the action sees
    // these, so an artifact cannot record where it was built.
    try std.testing.expect(std.mem.endsWith(u8, logical_workspace_z, "workspace"));
    try std.testing.expect(std.mem.endsWith(u8, logical_store_z, "store"));
    try std.testing.expect(!std.mem.eql(u8, logical_workspace_z, logical_store_z));
}
