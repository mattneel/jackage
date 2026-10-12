//! M06 acceptance cases exercise disposable directories and real executables.
//! Markers precede every setup/assertion, and optionals are checked before use.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("process.zig");
const artifact = @import("artifact.zig");
const profile = @import("manager.zig");
const runner = @import("runner.zig");
const digest = @import("../core/digest.zig");
const canonical = @import("../core/canonical.zig");
const tree = @import("../core/tree.zig");
const store_module = @import("../core/store.zig");
const resolver = @import("../plan/resolver.zig");
const cancel = @import("../core/cancel.zig");
const exec = @import("../exec/mod.zig");
const windows = @import("../exec/windows.zig");
const io = std.testing.io;
const gpa = std.testing.allocator;
const client_path = if (builtin.os.tag == .windows) "zig-out/bin/jckg.exe" else "zig-out/bin/jckg";
const read_payload: []const []const u8 = if (builtin.os.tag == .windows) &.{ "/d", "/c", "type payload.txt" } else &.{ "-c", "/bin/cat payload.txt" };
const exit_37: []const []const u8 = if (builtin.os.tag == .windows) &.{ "/d", "/c", "exit /b 37" } else &.{ "-c", "exit 37" };
const exit_wide: []const []const u8 = if (builtin.os.tag == .windows) &.{ "/d", "/c", "exit /b 1234567" } else &.{ "-c", "exit 1234567" };
const wide_native_status: u32 = if (builtin.os.tag == .windows) 1234567 else 1234567 % 256;

const LocalArtifact = struct { object: digest.Digest, payload: digest.Digest, executable: ?digest.Digest = null };
const Fixture = struct {
    path: []u8,
    root: std.Io.Dir,
    store_dir: std.Io.Dir,
    arena: std.heap.ArenaAllocator,
    fn init() !Fixture {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const path = try gpa.print(".zig-cache/m06-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
        errdefer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        const root = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer root.close(io);
        try root.createDirPath(io, "store");
        const store_dir = try root.openDir(io, "store", .{ .iterate = true });
        errdefer store_dir.close(io);
        var fixture: Fixture = .{ .path = path, .root = root, .store_dir = store_dir, .arena = .init(gpa) };
        try fixture.manager().ensureLayout();
        return fixture;
    }
    fn store(self: Fixture) store_module.Store { return .init(io, gpa, self.store_dir); }
    fn manager(self: Fixture) profile.Manager { return .init(io, gpa, self.root, self.store()); }
    fn deinit(self: *Fixture) void {
        self.store_dir.close(io);
        self.root.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        gpa.free(self.path);
        self.arena.deinit();
        self.* = undefined;
    }
    fn text(self: *Fixture, object: digest.Digest) ![]const u8 {
        var buffer: [digest.Digest.text_length]u8 = undefined;
        return self.arena.allocator().dupe(u8, object.text(&buffer));
    }
    fn selection(self: *Fixture, name: []const u8, object: digest.Digest, minor: u32) !resolver.Selection {
        return .{ .namespace = "local/trusted", .name = name, .version = .{ .major = 1, .minor = minor, .patch = 0 }, .artifact_digest = try self.text(object) };
    }
    fn package(self: *Fixture, label: []const u8, command_name: ?[]const u8, prefix: []const []const u8, dependencies: []const digest.Digest, executable_path: ?[]const u8) !LocalArtifact {
        const payload = try self.store().importBytes(label, null);
        var entries: [2]tree.Entry = undefined;
        var commands: [1]artifact.Command = undefined;
        var count: usize = 0;
        var executable: ?digest.Digest = null;
        if (command_name) |name| {
            const bytes = if (executable_path) |path| try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) else try gpa.dupe(u8, "verified bytes, not a native executable");
            defer gpa.free(bytes);
            const object = try self.store().importBytes(bytes, null);
            executable = object;
            entries[count] = .{ .path = "app.exe", .kind = .file, .digest = try self.text(object), .byte_length = bytes.len, .executable = true };
            count += 1;
            commands[0] = .{ .name = name, .path = "app.exe", .arguments = prefix };
        }
        entries[count] = .{ .path = "payload.txt", .kind = .file, .digest = try self.text(payload), .byte_length = label.len };
        count += 1;
        const dependency_texts = try self.arena.allocator().alloc([]const u8, dependencies.len);
        for (dependencies, dependency_texts) |dependency, *text_value| text_value.* = try self.text(dependency);
        const object = try self.manager().publish(.{ .files = entries[0..count], .commands = if (command_name != null) commands[0..1] else &.{}, .default_command = command_name, .dependencies = dependency_texts });
        return .{ .object = object, .payload = payload, .executable = executable };
    }
    fn client(self: *Fixture, label: []const u8, name: []const u8, prefix: []const []const u8, dependencies: []const digest.Digest) !LocalArtifact {
        return self.package(label, name, prefix, dependencies, client_path);
    }
    fn command(self: *Fixture, label: []const u8, name: []const u8, prefix: []const []const u8, dependencies: []const digest.Digest) !LocalArtifact {
        const command_path = if (builtin.os.tag == .windows) try windows.systemTool(gpa, "cmd.exe") else try gpa.dupe(u8, "/bin/sh");
        defer gpa.free(command_path);
        return self.package(label, name, prefix, dependencies, command_path);
    }
};

fn contains(closure: []const []const u8, object: digest.Digest) !bool {
    for (closure) |text| if ((try digest.Digest.parse(text)).eql(object)) return true;
    return false;
}
fn activeRequired(manager: profile.Manager, name: []const u8) !profile.Generation { return (try manager.active(name)) orelse error.ExpectedActiveGeneration; }
fn expectProgram(result: runner.Result, code: u32) !void {
    try std.testing.expectEqual(runner.Status.program, result.status);
    try std.testing.expectEqual(code, result.program_status orelse return error.MissingProgramStatus);
    try std.testing.expectEqual(code, result.callerStatus());
    try std.testing.expect(result.execution.cleanup_complete);
}
fn pause() !void { try std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = 5 * std.time.ns_per_ms }, .clock = .awake }, io); }
fn environmentSnapshot() !std.process.Environ.Map {
    if (builtin.os.tag == .windows) return (std.process.Environ{ .block = .global }).createMap(gpa);
    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    for (std.mem.span(std.c.environ)) |entry| {
        const bytes = std.mem.span(entry orelse continue);
        const equals = std.mem.indexOfScalar(u8, bytes, '=') orelse continue;
        try map.put(bytes[0..equals], bytes[equals + 1 ..]);
    }
    return map;
}

const Worker = struct {
    execution: *runner.Execution,
    options: runner.RunOptions = .{ .deadline_ns = 20 * std.time.ns_per_s },
    token: cancel.Token = .{},
    handle: ?std.Thread = null,
    result: ?runner.Result = null,
    failure: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    fn start(self: *Worker) !void { self.handle = try std.Thread.spawn(.{}, work, .{self}); }
    fn work(self: *Worker) void {
        self.result = self.execution.run(self.options, &self.token) catch |err| blk: { self.failure = err; break :blk null; };
        self.done.store(true, .release);
    }
    fn join(self: *Worker) void { if (self.handle) |handle| { handle.join(); self.handle = null; } }
    fn deinit(self: *Worker) void { self.token.request(); self.join(); if (self.result) |*result| result.deinit(); }
    fn waitRunning(self: *Worker, fixture: Fixture) !process.Identity {
        const journal_dir = try fixture.root.openDir(io, "profile-journal", .{});
        defer journal_dir.close(io);
        const journal: exec.Journal = .{ .dir = journal_dir, .io = io, .gpa = gpa };
        for (0..2000) |_| {
            if (journal.read(self.execution.lease.id())) |record| {
                defer record.deinit();
                if (record.value.phase == .running) if (record.value.process) |identity| if (process.state(io, gpa, identity) == .live) return identity;
            } else |err| if (err != error.FileNotFound) return err;
            if (self.done.load(.acquire)) return error.ProcessEndedBeforeObservation;
            try pause();
        }
        return error.ProcessStartNotObserved;
    }
    fn requireResult(self: *Worker) !runner.Result { self.join(); if (self.failure) |err| return err; return self.result orelse error.MissingRunnerResult; }
};

test "m06/PROFILE-001 Install a closure" {
    std.debug.print("JCKG_EVIDENCE PROFILE-001\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const dependency = try fixture.package("complete runtime dependency", null, &.{}, &.{}, null);
    const app = try fixture.client("trusted local package", "tool", &.{"version"}, &.{dependency.object});
    const app_selection = try fixture.selection("app", app.object, 0);
    const lib_selection = try fixture.selection("lib", dependency.object, 0);
    const pool = [_]resolver.Candidate{
        .{ .namespace = app_selection.namespace, .name = app_selection.name, .version = app_selection.version, .artifact_digest = app_selection.artifact_digest, .dependencies = &.{.{ .namespace = lib_selection.namespace, .name = lib_selection.name, .requirement = .any }} },
        .{ .namespace = lib_selection.namespace, .name = lib_selection.name, .version = lib_selection.version, .artifact_digest = lib_selection.artifact_digest },
    };
    var outcome = try resolver.resolve(gpa, &pool, &.{.{ .namespace = app_selection.namespace, .name = app_selection.name, .requirement = .any }});
    defer switch (outcome) { .resolved => |*resolution| resolution.deinit(), .conflict => |*conflict| conflict.deinit() };
    const resolution = switch (outcome) { .resolved => |resolution| resolution, .conflict => return error.UnexpectedConflict };
    var generation = try fixture.manager().install("default", resolution.selections, .{});
    defer generation.deinit();
    try std.testing.expectEqual(@as(usize, 2), generation.manifest().packages.len);
    try std.testing.expect(try contains(generation.manifest().closure, app.object));
    try std.testing.expect(try contains(generation.manifest().closure, dependency.object));
    try std.testing.expect(try contains(generation.manifest().closure, dependency.payload));
    try std.testing.expect(try contains(generation.manifest().closure, app.payload));
    try std.testing.expect(try contains(generation.manifest().closure, app.executable orelse return error.MissingExecutable));
    const selected_command = generation.command("tool") orelse return error.MissingCommand;
    try std.testing.expectEqualStrings(app_selection.artifact_digest, selected_command.artifact);
    var selected = try activeRequired(fixture.manager(), "default");
    defer selected.deinit();
    try std.testing.expectEqualStrings(generation.manifest().id, selected.manifest().id);
    const manifest_path = try gpa.print("profiles/default/generations/{s}.json", .{generation.manifest().id});
    defer gpa.free(manifest_path);
    const bytes = try fixture.root.readFileAlloc(io, manifest_path, gpa, .unlimited);
    defer gpa.free(bytes);
    var diagnostic: canonical.Diagnostic = .{};
    const document = try canonical.parse(gpa, bytes, &diagnostic);
    defer document.deinit(gpa);
    try std.testing.expect(canonical.isCanonical(document));
    const encoded = try canonical.encodeAlloc(gpa, document);
    defer gpa.free(encoded);
    try std.testing.expectEqualStrings(bytes, encoded);
    const absent = try fixture.selection("absent", digest.ofBlob("never available"), 0);
    try std.testing.expectError(error.UnknownObject, fixture.manager().install("default", &.{absent}, .{}));
    var unchanged = try activeRequired(fixture.manager(), "default");
    defer unchanged.deinit();
    try std.testing.expectEqualStrings(generation.manifest().id, unchanged.manifest().id);
}

const Stop = struct {
    point: profile.ActivationPoint,
    fn checkpoint(context: ?*anyopaque, point: profile.ActivationPoint) !void {
        const self: *const Stop = @ptrCast(@alignCast(context orelse return error.MissingCheckpointContext));
        if (self.point == point) return error.ActivationInterrupted;
    }
};

test "m06/PROFILE-002 Activate atomically" {
    std.debug.print("JCKG_EVIDENCE PROFILE-002\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const old = try fixture.client("old complete generation", "tool", &.{"version"}, &.{});
    const new = try fixture.client("new complete generation", "tool", &.{"version"}, &.{});
    const old_selection = try fixture.selection("app", old.object, 0);
    const new_selection = try fixture.selection("app", new.object, 1);
    for (std.enums.values(profile.ActivationPoint)) |point| {
        const name = try gpa.print("atomic-{s}", .{@tagName(point)});
        defer gpa.free(name);
        var prior = try fixture.manager().install(name, &.{old_selection}, .{});
        defer prior.deinit();
        var stop: Stop = .{ .point = point };
        try std.testing.expectError(error.ActivationInterrupted, fixture.manager().install(name, &.{new_selection}, .{ .context = &stop, .checkpoint = Stop.checkpoint }));
        // A fresh Manager is a restarted client: it uses only the durable files.
        const restarted = profile.Manager.init(io, gpa, fixture.root, fixture.store());
        var active = try activeRequired(restarted, name);
        defer active.deinit();
        if (point == .pointer_replaced) {
            try std.testing.expect(!std.mem.eql(u8, active.manifest().id, prior.manifest().id));
            try std.testing.expectEqualStrings(prior.manifest().id, active.manifest().parent orelse return error.ParentMissing);
            try std.testing.expect(try contains(active.manifest().closure, new.object));
            try std.testing.expect(try contains(active.manifest().closure, new.payload));
        } else {
            try std.testing.expectEqualStrings(prior.manifest().id, active.manifest().id);
            try std.testing.expect(try contains(active.manifest().closure, old.object));
            try std.testing.expect(!try contains(active.manifest().closure, new.payload));
        }
        const stale = try gpa.print("profiles/{s}/.active-stale", .{name});
        defer gpa.free(stale);
        try fixture.root.writeFile(io, .{ .sub_path = stale, .data = "not a complete generation" });
        var after_stale = try activeRequired(restarted, name);
        defer after_stale.deinit();
        try std.testing.expectEqualStrings(active.manifest().id, after_stale.manifest().id);
    }
    var stop: Stop = .{ .point = .pointer_flushed };
    try std.testing.expectError(error.ActivationInterrupted, fixture.manager().install("first-interrupted", &.{new_selection}, .{ .context = &stop, .checkpoint = Stop.checkpoint }));
    var absent = try fixture.manager().active("first-interrupted");
    defer if (absent) |*generation| generation.deinit();
    try std.testing.expect(absent == null);
}

test "m06/PROFILE-003 Rollback a generation" {
    std.debug.print("JCKG_EVIDENCE PROFILE-003\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const old_dependency = try fixture.package("earlier runtime library", null, &.{}, &.{}, null);
    const new_dependency = try fixture.package("upgraded runtime library", null, &.{}, &.{}, null);
    const old = try fixture.command("earlier package closure", "tool", read_payload, &.{old_dependency.object});
    const new = try fixture.command("upgraded package closure", "tool", read_payload, &.{new_dependency.object});
    var first = try fixture.manager().install("default", &.{try fixture.selection("app", old.object, 0)}, .{});
    defer first.deinit();
    var second = try fixture.manager().install("default", &.{try fixture.selection("app", new.object, 1)}, .{});
    defer second.deinit();
    var rollback = try fixture.manager().rollback("default", null);
    defer rollback.deinit();
    try std.testing.expectEqualStrings(first.manifest().id, rollback.manifest().id);
    const command = rollback.command("tool") orelse return error.MissingCommand;
    try std.testing.expect((try digest.Digest.parse(command.artifact)).eql(old.object));
    try std.testing.expect(try contains(rollback.manifest().closure, old_dependency.payload));
    try std.testing.expect(!try contains(rollback.manifest().closure, new_dependency.payload));
    var execution = try runner.prepareCommand(fixture.manager(), "default", "tool", &.{});
    defer execution.deinit();
    var token: cancel.Token = .{};
    var result = try execution.run(.{}, &token);
    defer result.deinit();
    try expectProgram(result, 0);
    try std.testing.expectEqualStrings("earlier package closure", result.execution.stdout);
    try std.testing.expectError(error.InvalidGenerationId, fixture.manager().rollback("default", "invalid"));
    var unchanged = try activeRequired(fixture.manager(), "default");
    defer unchanged.deinit();
    try std.testing.expectEqualStrings(first.manifest().id, unchanged.manifest().id);
}

test "m06/PROFILE-004 Remove references safely" {
    std.debug.print("JCKG_EVIDENCE PROFILE-004\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.root.createDirPath(io, "user-source");
    try fixture.root.writeFile(io, .{ .sub_path = "user-source/package.ts", .data = "user-owned trusted local source\n" });
    const shared = try fixture.package("shared runtime dependency", null, &.{}, &.{}, null);
    const first = try fixture.client("removed package", "first", &.{"version"}, &.{shared.object});
    const second = try fixture.client("surviving package", "second", &.{"version"}, &.{shared.object});
    var initial = try fixture.manager().install("default", &.{ try fixture.selection("first", first.object, 0), try fixture.selection("second", second.object, 0) }, .{});
    defer initial.deinit();
    var removed = try fixture.manager().remove("default", "local/trusted", "first", .{});
    defer removed.deinit();
    try std.testing.expectEqual(@as(usize, 1), removed.manifest().packages.len);
    try std.testing.expect(removed.command("first") == null);
    try std.testing.expect(removed.command("second") != null);
    try std.testing.expect(!try contains(removed.manifest().closure, first.object));
    try std.testing.expect(try contains(removed.manifest().closure, shared.payload));
    const report = try fixture.manager().collect(.{ .keep_generations = 1 });
    try std.testing.expect(report.deleted_generations >= 1);
    try std.testing.expect(!fixture.store().hasBlob(first.object));
    try std.testing.expect(!fixture.store().hasBlob(first.payload));
    try std.testing.expect(fixture.store().hasBlob(second.object));
    try std.testing.expect(fixture.store().hasBlob(shared.object));
    const library = try fixture.store().readBlobAlloc(gpa, shared.payload);
    defer gpa.free(library);
    try std.testing.expectEqualStrings("shared runtime dependency", library);
    const source = try fixture.root.readFileAlloc(io, "user-source/package.ts", gpa, .unlimited);
    defer gpa.free(source);
    try std.testing.expectEqualStrings("user-owned trusted local source\n", source);
    try std.testing.expectError(error.PackageNotInstalled, fixture.manager().remove("default", "local/trusted", "unknown", .{}));
}

test "m06/PROFILE-005 Handle executable collision" {
    std.debug.print("JCKG_EVIDENCE PROFILE-005\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const first = try fixture.client("first command owner", "tool", &.{"version"}, &.{});
    const second = try fixture.client("second command owner", if (builtin.os.tag == .windows) "TOOL" else "tool", &.{"version"}, &.{});
    const selections = [_]resolver.Selection{ try fixture.selection("first", first.object, 0), try fixture.selection("second", second.object, 0) };
    var initial = try fixture.manager().install("default", selections[0..1], .{});
    defer initial.deinit();
    var collision: profile.Collision = .{};
    try std.testing.expectError(error.CommandCollision, fixture.manager().install("default", &selections, .{ .collision = &collision }));
    try std.testing.expectEqualStrings("tool", collision.commandName());
    try std.testing.expectEqualStrings("local/trusted/first", collision.firstPackage());
    try std.testing.expectEqualStrings("local/trusted/second", collision.secondPackage());
    var unchanged = try activeRequired(fixture.manager(), "default");
    defer unchanged.deinit();
    try std.testing.expectEqualStrings(initial.manifest().id, unchanged.manifest().id);
    const owners = [_]profile.CommandOwner{.{ .command = "tool", .namespace = "local/trusted", .package = "second" }};
    var explicit = try fixture.manager().install("default", &selections, .{ .owners = &owners });
    defer explicit.deinit();
    const selected = explicit.command("tool") orelse return error.MissingCommand;
    try std.testing.expectEqualStrings("second", selected.package);
    try std.testing.expect((try digest.Digest.parse(selected.artifact)).eql(second.object));
    var reordered = try fixture.manager().install("default", &.{ selections[1], selections[0] }, .{ .owners = &owners });
    defer reordered.deinit();
    try std.testing.expectEqualStrings("second", (reordered.command("tool") orelse return error.MissingCommand).package);
    try std.testing.expectError(error.InvalidCommandOwner, fixture.manager().install("default", &selections, .{ .owners = &.{.{ .command = "tool", .namespace = "local/trusted", .package = "absent" }} }));
}

test "m06/PROFILE-006 Preserve active executable" {
    std.debug.print("JCKG_EVIDENCE PROFILE-006\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const dependency = try fixture.package("active library retained until final lease ends", null, &.{}, &.{}, null);
    const old = try fixture.client("old active payload", "tool", &.{ "doctor", "--json", "--watch", "--deadline-ms", "1800" }, &.{dependency.object});
    const new = try fixture.client("new generation payload", "tool", &.{"version"}, &.{});
    var initial = try fixture.manager().install("default", &.{try fixture.selection("app", old.object, 0)}, .{});
    defer initial.deinit();
    var keeper = try fixture.manager().leaseActive("default");
    defer keeper.generation.deinit();
    defer keeper.lease.deinit();
    var recovered = try fixture.manager().readLease("default", keeper.lease.id());
    defer recovered.deinit();
    const owner = try recovered.parsed.value.owner.identity();
    const caller = try process.current(io, gpa);
    try std.testing.expectEqual(caller.pid, owner.pid);
    try std.testing.expectEqual(caller.created, owner.created);
    try std.testing.expect(recovered.parsed.value.started_ms > 0);
    try std.testing.expectEqual(initial.manifest().closure.len, recovered.parsed.value.closure.len);
    var blob_buffer: [128]u8 = undefined;
    const open_file = try fixture.store_dir.openFile(io, fixture.store().blobPath(old.executable orelse return error.MissingExecutable, &blob_buffer), .{});
    var file_open = true;
    defer if (file_open) open_file.close(io);
    var execution = try runner.prepareCommand(fixture.manager(), "default", "tool", &.{});
    defer execution.deinit();
    var worker: Worker = .{ .execution = &execution };
    defer worker.deinit();
    try worker.start();
    const holder = try worker.waitRunning(fixture);
    try std.testing.expectEqual(process.State.live, process.state(io, gpa, holder));
    try std.testing.expectError(error.LeaseHolderActive, execution.lease.release());
    var upgraded = try fixture.manager().install("default", &.{try fixture.selection("app", new.object, 1)}, .{});
    defer upgraded.deinit();
    const during = try fixture.manager().collect(.{ .keep_generations = 1 });
    try std.testing.expectEqual(@as(usize, 2), during.retained_leases);
    try std.testing.expect(during.retained_generations >= 2);
    try std.testing.expect(fixture.store().hasBlob(old.object));
    const library = try fixture.store().readBlobAlloc(gpa, dependency.payload);
    defer gpa.free(library);
    try std.testing.expectEqualStrings("active library retained until final lease ends", library);
    const copied_payload = try execution.workspace.readFileAlloc(io, "payload.txt", gpa, .unlimited);
    defer gpa.free(copied_payload);
    try std.testing.expectEqualStrings("old active payload", copied_payload);
    const result = try worker.requireResult();
    try expectProgram(result, 0);
    try std.testing.expect(!result.workspace_retained);
    const with_open_file = try fixture.manager().collect(.{ .keep_generations = 1 });
    try std.testing.expectEqual(@as(usize, 1), with_open_file.retained_leases);
    try std.testing.expect(fixture.store().hasBlob(dependency.payload));
    try std.testing.expect((try open_file.stat(io)).size > 0);
    open_file.close(io);
    file_open = false;
    try keeper.lease.release();
    const after = try fixture.manager().collect(.{ .keep_generations = 1 });
    try std.testing.expectEqual(@as(usize, 0), after.retained_leases);
    try std.testing.expect(!fixture.store().hasBlob(old.object));
    try std.testing.expect(!fixture.store().hasBlob(dependency.payload));
}

test "m06/PROFILE-007 Run transiently" {
    std.debug.print("JCKG_EVIDENCE PROFILE-007\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const installed = try fixture.client("installed selection", "installed", &.{"version"}, &.{});
    const transient = try fixture.client("verified transient package", "tool", &.{"version"}, &.{});
    var generation = try fixture.manager().install("default", &.{try fixture.selection("installed", installed.object, 0)}, .{});
    defer generation.deinit();
    const before = try fixture.root.readFileAlloc(io, "profiles/default/active", gpa, .unlimited);
    defer gpa.free(before);
    const manifest_path = try gpa.print("profiles/default/generations/{s}.json", .{generation.manifest().id});
    defer gpa.free(manifest_path);
    const manifest_before = try fixture.root.readFileAlloc(io, manifest_path, gpa, .unlimited);
    defer gpa.free(manifest_before);
    var environment_before = try environmentSnapshot();
    defer environment_before.deinit();
    const path_before = try gpa.dupe(u8, environment_before.get("PATH") orelse "");
    defer gpa.free(path_before);
    var token: cancel.Token = .{};
    var result = try runner.runTransient(fixture.manager(), transient.object, &.{}, .{ .environment = &.{.{ .name = "PATH", .value = "private-child-only" }} }, &token);
    defer result.deinit();
    try expectProgram(result, 0);
    try std.testing.expect(std.mem.indexOf(u8, result.execution.stdout, "jackage") != null);
    try std.testing.expect(!result.workspace_retained);
    const after = try fixture.root.readFileAlloc(io, "profiles/default/active", gpa, .unlimited);
    defer gpa.free(after);
    const manifest_after = try fixture.root.readFileAlloc(io, manifest_path, gpa, .unlimited);
    defer gpa.free(manifest_after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqualStrings(manifest_before, manifest_after);
    var environment_after = try environmentSnapshot();
    defer environment_after.deinit();
    try std.testing.expectEqualStrings(path_before, environment_after.get("PATH") orelse "");
    var active = try activeRequired(fixture.manager(), "default");
    defer active.deinit();
    try std.testing.expect(!try contains(active.manifest().closure, transient.object));
    const report = try fixture.manager().collect(.{ .mode = .dry_run });
    try std.testing.expectEqual(@as(usize, 0), report.retained_leases);
}

test "m06/PROFILE-008 Forward runner arguments" {
    std.debug.print("JCKG_EVIDENCE PROFILE-008\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const package = try fixture.client("argv package", "tool", &.{ "echo", "--json", "--" }, &.{});
    const expected = [_][]const u8{ "--help", "--", "--repo", "not-a-runner-option", "with spaces", "a\"quoted\"value", "", "trailing\\", "ünïcödé-路径", "&|<>^%PATH%" };
    const input = [_][]const u8{ "--repo", "https://example.invalid/repo", "package", "--" } ++ expected;
    const invocation = try runner.parse(&input);
    try std.testing.expectEqualStrings("https://example.invalid/repo", invocation.repository orelse return error.RepositoryMissing);
    try std.testing.expectEqualStrings("package", invocation.package);
    try std.testing.expectEqual(expected.len, invocation.arguments.len);
    for (expected, invocation.arguments) |left, right| try std.testing.expectEqualStrings(left, right);
    var token: cancel.Token = .{};
    var result = try runner.runTransient(fixture.manager(), package.object, invocation.arguments, .{}, &token);
    defer result.deinit();
    try expectProgram(result, 0);
    const Document = struct { count: usize, shellEvaluation: bool, tokens: []const struct { value: []const u8 } };
    const parsed = try std.json.parseFromSlice(Document, gpa, result.execution.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(expected.len + 1, parsed.value.count);
    try std.testing.expectEqual(expected.len + 1, parsed.value.tokens.len);
    try std.testing.expect(!parsed.value.shellEvaluation);
    for (expected, 0..) |argument, index| try std.testing.expectEqualStrings(argument, parsed.value.tokens[index + 1].value);
    const without_separator = try runner.parse(&.{ "package", "--help", "--repo", "literal" });
    try std.testing.expectEqual(@as(usize, 3), without_separator.arguments.len);
    try std.testing.expectEqualStrings("--help", without_separator.arguments[0]);
    const twice = try runner.parse(&.{ "package", "--", "--", "quoted argument" });
    try std.testing.expectEqual(@as(usize, 2), twice.arguments.len);
    try std.testing.expectEqualStrings("--", twice.arguments[0]);
    try std.testing.expectError(error.PackageRequired, runner.parse(&.{}));
    try std.testing.expectError(error.RepositoryRequired, runner.parse(&.{"--repo"}));
    try std.testing.expectError(error.InvalidRunnerOption, runner.parse(&.{ "--unknown", "package" }));
}

test "m06/PROFILE-009 Preserve runner exit" {
    std.debug.print("JCKG_EVIDENCE PROFILE-009\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const failing = try fixture.command("unsuccessful native program", "tool", exit_37, &.{});
    var token: cancel.Token = .{};
    var failed = try runner.runTransient(fixture.manager(), failing.object, &.{}, .{}, &token);
    defer failed.deinit();
    try expectProgram(failed, 37);
    try std.testing.expect(failed.execution.cause == null);
    const wide = try fixture.command("full native status", "tool", exit_wide, &.{});
    var wide_result = try runner.runTransient(fixture.manager(), wide.object, &.{}, .{}, &token);
    defer wide_result.deinit();
    try expectProgram(wide_result, wide_native_status);
    const unlaunchable = try fixture.package("launch failure", "tool", &.{}, &.{}, null);
    var launch = try runner.runTransient(fixture.manager(), unlaunchable.object, &.{}, .{}, &token);
    defer launch.deinit();
    try std.testing.expectEqual(runner.Status.launch_failure, launch.status);
    try std.testing.expect(launch.program_status == null);
    try std.testing.expect(launch.execution.exit_code == null);
    try std.testing.expect(launch.execution.cause != null);
    try std.testing.expectEqual(@as(u32, 127), launch.callerStatus());
    try std.testing.expect(!launch.workspace_retained);
}

test "m06/PROFILE-010 Lease concurrent runners" {
    std.debug.print("JCKG_EVIDENCE PROFILE-010\n", .{});
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const dependency = try fixture.package("concurrent runtime dependency", null, &.{}, &.{}, null);
    const package = try fixture.client("never share this writable workspace", "tool", &.{ "doctor", "--json", "--watch" }, &.{dependency.object});
    var first = try runner.prepareTransient(fixture.manager(), package.object, null, &.{ "--deadline-ms", "650" });
    defer first.deinit();
    var second = try runner.prepareTransient(fixture.manager(), package.object, null, &.{ "--deadline-ms", "3000" });
    defer second.deinit();
    try std.testing.expect(!std.mem.eql(u8, first.workspace_path, second.workspace_path));
    try std.testing.expect(!std.mem.eql(u8, first.program, second.program));
    try first.workspace.writeFile(io, .{ .sub_path = "payload.txt", .data = "first runner's private mutation" });
    const second_payload = try second.workspace.readFileAlloc(io, "payload.txt", gpa, .unlimited);
    defer gpa.free(second_payload);
    try std.testing.expectEqualStrings("never share this writable workspace", second_payload);
    const immutable = try fixture.store().readBlobAlloc(gpa, package.payload);
    defer gpa.free(immutable);
    try std.testing.expectEqualStrings("never share this writable workspace", immutable);
    var first_worker: Worker = .{ .execution = &first };
    defer first_worker.deinit();
    var second_worker: Worker = .{ .execution = &second };
    defer second_worker.deinit();
    try first_worker.start();
    _ = try first_worker.waitRunning(fixture);
    try second_worker.start();
    const second_process = try second_worker.waitRunning(fixture);
    const first_result = try first_worker.requireResult();
    try expectProgram(first_result, 0);
    try std.testing.expectEqual(process.State.live, process.state(io, gpa, second_process));
    const during = try fixture.manager().collect(.{ .keep_generations = 1 });
    try std.testing.expectEqual(@as(usize, 1), during.retained_leases);
    try std.testing.expect(fixture.store().hasBlob(package.object));
    try std.testing.expect(fixture.store().hasBlob(package.payload));
    try std.testing.expect(fixture.store().hasBlob(dependency.object));
    try std.testing.expect(fixture.store().hasBlob(dependency.payload));
    const library = try fixture.store().readBlobAlloc(gpa, dependency.payload);
    defer gpa.free(library);
    try std.testing.expectEqualStrings("concurrent runtime dependency", library);
    const second_result = try second_worker.requireResult();
    try expectProgram(second_result, 0);
    try std.testing.expect(!second_result.workspace_retained);
    const after = try fixture.manager().collect(.{ .keep_generations = 1 });
    try std.testing.expectEqual(@as(usize, 0), after.retained_leases);
    try std.testing.expect(!fixture.store().hasBlob(package.object));
    try std.testing.expect(!fixture.store().hasBlob(dependency.payload));
}
