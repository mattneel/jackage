//! Sandbox launch plan for the strict Linux worker (M08: STRICT-001..005).
//!
//! The plan is data: which host paths are bound into the namespace, at which
//! *logical* paths, which of them are writable, the exact argv to execute, and
//! the resource bounds to apply. Two rules shape everything here:
//!
//! 1. **No shell, ever.** The worker process itself performs the mounts inside
//!    the namespace and then `execve`s the action argv directly, so argument
//!    boundaries survive by construction instead of by quoting.
//! 2. **Stable logical paths.** An action sees its inputs at fixed logical
//!    paths (`/jckg/workspace`, `/jckg/store`) regardless of the physical
//!    checkout or store location, so absolute host paths cannot leak into
//!    artifacts and a second build under different roots can be compared.
const std = @import("std");

/// The mount point the worker builds the action's whole view under.
pub const logical_root = "/jckg";
pub const logical_workspace = "/jckg/workspace";
pub const logical_store = "/jckg/store";
pub const logical_tmp = "/tmp";

pub const Error = error{
    OutOfMemory,
    InvalidPlan,
    UnsafePath,
    UndeclaredWritablePath,
    MissingExecutable,
    DuplicateBindTarget,
    UnsupportedNetwork,
};

pub const NetworkPolicy = enum {
    /// No network interfaces: the network namespace is created and left down.
    none,
    /// Loopback only, for tests that need to talk to themselves.
    loopback,
};

pub const Bind = struct {
    /// Host path. Must be absolute and free of `.`/`..` components.
    source: []const u8,
    /// Logical path inside the namespace.
    target: []const u8,
    writable: bool = false,
};

pub const Limits = struct {
    max_processes: u32 = 256,
    max_memory_bytes: u64 = 2 * 1024 * 1024 * 1024,
    max_file_bytes: u64 = 8 * 1024 * 1024 * 1024,
    deadline_ms: u64 = 15 * 60 * 1000,
};

pub const Plan = struct {
    /// Host path bound writable at `logical_workspace`.
    workspace: []const u8,
    /// Host path bound read-only at `logical_store`.
    store: []const u8,
    /// Exact argv for the action; `argv[0]` names the program.
    argv: []const []const u8,
    /// Declared environment, as `KEY=value` entries. Empty by default: an
    /// action gets nothing it did not declare.
    environment: []const []const u8 = &.{},
    network: NetworkPolicy = .none,
    limits: Limits = .{},
    /// Extra binds, all read-only unless a writable path is declared here.
    extra_binds: []const Bind = &.{},
    /// Host paths that may be writable; everything else in the namespace is
    /// read-only. A writable bind must appear here.
    writable_paths: []const []const u8 = &.{},

    pub fn deinit(self: *Plan, gpa: std.mem.Allocator) void {
        gpa.free(self.workspace);
        gpa.free(self.store);
        for (self.argv) |argument| gpa.free(argument);
        gpa.free(self.argv);
        for (self.environment) |entry| gpa.free(entry);
        gpa.free(self.environment);
        for (self.extra_binds) |bind| {
            gpa.free(bind.source);
            gpa.free(bind.target);
        }
        gpa.free(self.extra_binds);
        for (self.writable_paths) |entry| gpa.free(entry);
        gpa.free(self.writable_paths);
        self.* = undefined;
    }
};

/// A host path that may be bound into the namespace: absolute, no traversal,
/// no backslashes, no NUL, valid UTF-8.
pub fn safeHostPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096) return false;
    if (path[0] != '/') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

/// Validates a plan without executing anything.
pub fn validate(plan: Plan) Error!void {
    if (plan.argv.len == 0) return error.MissingExecutable;
    if (plan.argv[0].len == 0) return error.MissingExecutable;
    if (!safeHostPath(plan.workspace)) return error.UnsafePath;
    if (!safeHostPath(plan.store)) return error.UnsafePath;
    if (plan.limits.max_processes == 0 or plan.limits.max_memory_bytes == 0 or plan.limits.deadline_ms == 0) {
        return error.InvalidPlan;
    }

    var targets: std.ArrayList([]const u8) = .empty;
    defer targets.deinit(std.heap.page_allocator);
    for (plan.extra_binds) |bind| {
        if (!safeHostPath(bind.source)) return error.UnsafePath;
        if (bind.target.len == 0 or bind.target[0] != '/') return error.UnsafePath;
        for (targets.items) |existing| {
            if (std.mem.eql(u8, existing, bind.target)) return error.DuplicateBindTarget;
        }
        try targets.append(std.heap.page_allocator, bind.target);

        if (bind.writable and !declaredWritable(plan, bind.source)) {
            return error.UndeclaredWritablePath;
        }
    }
    if (!declaredWritable(plan, plan.workspace)) {
        // The workspace is writable by definition; the declaration list exists
        // so that *extra* writable mounts cannot appear silently.
    }
    for (plan.writable_paths) |path| {
        if (!safeHostPath(path)) return error.UnsafePath;
    }
}

fn declaredWritable(plan: Plan, path: []const u8) bool {
    for (plan.writable_paths) |declared| {
        if (std.mem.eql(u8, declared, path)) return true;
    }
    return false;
}

/// The `unshare` preamble that creates the namespace the worker then sets up.
///
/// The worker is the *first* program in the namespace and does the mounts
/// itself, then `execve`s the action argv - there is no shell between the two
/// steps, so no quoting layer can reinterpret an argument.
pub fn namespacePreamble(gpa: std.mem.Allocator, worker_path: []const u8, plan_path: []const u8, network: NetworkPolicy) Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |entry| gpa.free(entry);
        argv.deinit(gpa);
    }

    const flag = struct {
        fn add(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, text: []const u8) !void {
            try list.append(allocator, try allocator.dupe(u8, text));
        }
    }.add;

    try flag(&argv, gpa, "unshare");
    try flag(&argv, gpa, "--user");
    try flag(&argv, gpa, "--map-root-user");
    try flag(&argv, gpa, "--mount");
    try flag(&argv, gpa, "--pid");
    try flag(&argv, gpa, "--fork");
    try flag(&argv, gpa, "--mount-proc");
    switch (network) {
        .none => try flag(&argv, gpa, "--net"),
        .loopback => try flag(&argv, gpa, "--net"),
    }
    try flag(&argv, gpa, "--");
    try flag(&argv, gpa, worker_path);
    try flag(&argv, gpa, "--sandbox");
    try flag(&argv, gpa, plan_path);
    return argv.toOwnedSlice(gpa);
}

/// The logical path an input is visible at, inside the namespace.
pub fn logicalPathFor(bind: Bind) []const u8 {
    return bind.target;
}

test "m08/sandbox plan validates paths, writability and argv" {
    const gpa = std.testing.allocator;

    const argv = try gpa.alloc([]const u8, 2);
    argv[0] = try gpa.dupe(u8, "/jckg/workspace/bin/tool");
    argv[1] = try gpa.dupe(u8, "--flag=value with spaces");

    var plan = Plan{
        .workspace = try gpa.dupe(u8, "/home/user/jckg/run-1"),
        .store = try gpa.dupe(u8, "/home/user/jckg/store"),
        .argv = argv,
    };
    defer plan.deinit(gpa);

    // A well-formed plan validates, and the exact argv is preserved with its
    // embedded space: nothing here reinterprets arguments.
    try validate(plan);
    try std.testing.expectEqualStrings("--flag=value with spaces", plan.argv[1]);

    // Traversal, relative paths and Windows separators are refused.
    const bad_workspace = "/home/user/../etc";
    var traversal = plan;
    traversal.workspace = @constCast(bad_workspace);
    try std.testing.expectError(error.UnsafePath, validate(traversal));

    var relative = plan;
    relative.workspace = @constCast("home/user/run");
    try std.testing.expectError(error.UnsafePath, validate(relative));

    var backslashes = plan;
    backslashes.store = @constCast("/home/user\\jckg\\store");
    try std.testing.expectError(error.UnsafePath, validate(backslashes));

    // An empty argv is not executable, and zero limits are not a policy.
    var no_argv = plan;
    no_argv.argv = &.{};
    try std.testing.expectError(error.MissingExecutable, validate(no_argv));

    var no_limits = plan;
    no_limits.limits = .{ .max_processes = 0 };
    try std.testing.expectError(error.InvalidPlan, validate(no_limits));

    // A writable bind that was not declared is refused: writable access is an
    // explicit grant, not a default.
    const binds = try gpa.alloc(Bind, 1);
    defer {
        for (binds) |bind| {
            gpa.free(bind.source);
            gpa.free(bind.target);
        }
        gpa.free(binds);
    }
    binds[0] = .{
        .source = try gpa.dupe(u8, "/home/user/jckg/cache"),
        .target = try gpa.dupe(u8, "/jckg/cache"),
        .writable = true,
    };
    var undeclared = plan;
    undeclared.extra_binds = binds;
    try std.testing.expectError(error.UndeclaredWritablePath, validate(undeclared));

    // Declaring it makes the same plan valid, and a duplicate target is still
    // refused: two mounts on one logical path would be ambiguous.
    const writable = try gpa.alloc([]const u8, 1);
    defer {
        gpa.free(writable[0]);
        gpa.free(writable);
    }
    writable[0] = try gpa.dupe(u8, "/home/user/jckg/cache");
    undeclared.writable_paths = writable;
    try validate(undeclared);

    const duplicate = try gpa.alloc(Bind, 2);
    defer {
        gpa.free(duplicate[1].source);
        gpa.free(duplicate[1].target);
        gpa.free(duplicate);
    }
    duplicate[0] = binds[0];
    duplicate[1] = .{
        .source = try gpa.dupe(u8, "/home/user/jckg/cache"),
        .target = try gpa.dupe(u8, "/jckg/cache"),
        .writable = false,
    };
    var duplicated = plan;
    duplicated.extra_binds = duplicate;
    duplicated.writable_paths = writable;
    try std.testing.expectError(error.DuplicateBindTarget, validate(duplicated));

    // The namespace preamble creates the namespaces and hands control to the
    // worker, never to a shell. (`unshare` itself contains "sh", so the check
    // is on program names and the `-c` form, not on substrings.)
    const preamble = try namespacePreamble(gpa, "/usr/local/bin/jckg-worker", "/run/plan.json", .none);
    defer {
        for (preamble) |entry| gpa.free(entry);
        gpa.free(preamble);
    }
    try std.testing.expectEqualStrings("unshare", preamble[0]);
    for (preamble) |entry| {
        const base = std.fs.path.basename(entry);
        try std.testing.expect(!std.mem.eql(u8, base, "sh"));
        try std.testing.expect(!std.mem.eql(u8, base, "bash"));
        try std.testing.expect(!std.mem.eql(u8, entry, "-c"));
    }
    var saw_user = false;
    var saw_net = false;
    var saw_separator = false;
    for (preamble) |entry| {
        if (std.mem.eql(u8, entry, "--user")) saw_user = true;
        if (std.mem.eql(u8, entry, "--net")) saw_net = true;
        if (std.mem.eql(u8, entry, "--")) saw_separator = true;
    }
    try std.testing.expect(saw_user and saw_net and saw_separator);
    // Nothing after the separator is a shell: the worker is executed directly.
    var separator_index: usize = 0;
    for (preamble, 0..) |entry, index| {
        if (std.mem.eql(u8, entry, "--")) separator_index = index;
    }
    try std.testing.expectEqualStrings("/usr/local/bin/jckg-worker", preamble[separator_index + 1]);
    try std.testing.expectEqualStrings("--sandbox", preamble[separator_index + 2]);
    try std.testing.expectEqualStrings("/run/plan.json", preamble[separator_index + 3]);

    // The logical paths are fixed, so an artifact never embeds a host path.
    try std.testing.expectEqualStrings("/jckg/workspace", logicalPathFor(.{ .source = "/anywhere", .target = logical_workspace }));
    try std.testing.expectEqualStrings("/jckg/store", logical_store);
}
