//! Host acceptance cases use installed tools and disposable .zig-cache trees.
const std = @import("std");
const builtin = @import("builtin");
const native = @import("native.zig");
const windows = @import("windows.zig");
const journal_module = @import("journal.zig");
const cancel = @import("../core/cancel.zig");
const capabilities = @import("../core/capabilities.zig");
const store_module = @import("../core/store.zig");
const digest = @import("../core/digest.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

const Fixture = struct {
    path: []u8,
    root: std.Io.Dir,
    workspace: std.Io.Dir,
    store_dir: std.Io.Dir,
    journal_dir: std.Io.Dir,
    client: [:0]u8,
    command: []u8,

    fn init() !Fixture {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/m03-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
        errdefer gpa.free(path);
        try std.Io.Dir.cwd().createDirPath(io, path);
        errdefer std.Io.Dir.cwd().deleteTree(io, path) catch {};
        const root = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer root.close(io);
        try root.createDirPath(io, "workspace");
        try root.createDirPath(io, "store");
        try root.createDirPath(io, "journal");
        const workspace = try root.openDir(io, "workspace", .{ .iterate = true });
        errdefer workspace.close(io);
        const store_dir = try root.openDir(io, "store", .{ .iterate = true });
        errdefer store_dir.close(io);
        const journal_dir = try root.openDir(io, "journal", .{ .iterate = true });
        errdefer journal_dir.close(io);
        const client = try std.Io.Dir.cwd().realPathFileAlloc(io, "zig-out/bin/jckg.exe", gpa);
        errdefer gpa.free(client);
        const command = try windows.systemTool(gpa, "cmd.exe");
        errdefer gpa.free(command);
        const fixture: Fixture = .{ .path = path, .root = root, .workspace = workspace, .store_dir = store_dir, .journal_dir = journal_dir, .client = client, .command = command };
        try fixture.store().ensureLayout();
        return fixture;
    }

    fn store(self: Fixture) store_module.Store {
        return store_module.Store.init(io, gpa, self.store_dir);
    }

    fn journal(self: Fixture) journal_module.Journal {
        return .{ .dir = self.journal_dir, .io = io, .gpa = gpa };
    }

    fn executor(self: Fixture) native.Executor {
        return .{ .io = io, .gpa = gpa, .store = self.store(), .journal = self.journal() };
    }

    fn request(self: Fixture, id: []const u8) native.Request {
        return .{ .action_id = id, .program = self.command, .workspace = self.workspace, .deadline_ns = 20 * std.time.ns_per_s };
    }

    fn deinit(self: *Fixture) void {
        self.workspace.close(io);
        self.store_dir.close(io);
        self.journal_dir.close(io);
        self.root.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
        gpa.free(self.client);
        gpa.free(self.command);
        gpa.free(self.path);
        self.* = undefined;
    }
};

fn expectExit(result: native.Result, code: u32) !void {
    const actual = result.exit_code orelse return error.MissingProcessExit;
    try std.testing.expectEqual(code, actual);
}

fn expectStatus(expected: native.Status, result: native.Result) !void {
    if (result.status != expected) std.debug.print(
        "executor status={s}, cause={s}, exit={any}, cleanup={}; stderr={s}\n",
        .{ @tagName(result.status), if (result.cause) |cause| @errorName(cause) else "none", result.exit_code, result.cleanup_complete, result.stderr },
    );
    try std.testing.expectEqual(expected, result.status);
}

fn expectCompleted(fixture: Fixture, action_id: []const u8, status: []const u8) !void {
    const record = try fixture.journal().read(action_id);
    defer record.deinit();
    try std.testing.expectEqual(journal_module.Phase.completed, record.value.phase);
    const actual = record.value.result_status orelse return error.MissingJournalResult;
    try std.testing.expectEqualStrings(status, actual);
    const observation = try fixture.journal().reconcile(action_id);
    try std.testing.expect(observation.safe_to_retry);
}

/// Guest compilation does not imply a POSIX execution implementation. Exercise
/// an honest refusal, not SkipZigTest or a fake successful process result.
fn expectUnavailableHost() !void {
    const backend = native.nativeBackend();
    for ([_][]const u8{ "process.argv", "process.spawn", "process.cleanup", "environment.declared", "filesystem.isolation", "network.isolation" }) |name| {
        const capability = backend.find(name) orelse return error.MissingUnavailableCapability;
        try std.testing.expectEqual(capabilities.Status.unavailable, capability.status);
        try std.testing.expect(capability.evidence.len > 0);
        try std.testing.expectError(error.CapabilityUnavailable, native.requireCapabilities(&.{name}));
    }
    var token: cancel.Token = .{};
    const executor: native.Executor = .{
        .io = io,
        .gpa = gpa,
        .store = store_module.Store.init(io, gpa, .cwd()),
        .journal = .{ .dir = .cwd(), .io = io, .gpa = gpa },
    };
    try std.testing.expectError(error.NativePlatformUnavailable, executor.run(.{
        .action_id = "unsupported-native-target",
        .program = "/platform-unavailable",
        .workspace = .cwd(),
    }, &token));
}

test "m03/EXE-001 Execute exact argv" {
    std.debug.print("JCKG_EVIDENCE EXE-001\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var token: cancel.Token = .{};
    const arguments = [_][]const u8{ "with spaces", "a\"quoted\"value", "&|<>^%PATH%", "", "trailing\\", "'literal'", "$(no-shell)", "--flag=value", "\"%JCKG_M03_EXPAND%\" & echo hostile" };
    const argv = [_][]const u8{ "echo", "--json", "--" } ++ arguments;
    var request = fixture.request("exact-argv");
    request.program = fixture.client;
    request.argv = &argv;
    request.environment = &.{.{ .name = "JCKG_M03_EXPAND", .value = "expanded-would-be-wrong" }};
    var result = try fixture.executor().run(request, &token);
    defer result.deinit();
    try std.testing.expectEqual(native.Status.success, result.status);
    try expectExit(result, 0);
    const Document = struct {
        count: usize,
        shellEvaluation: bool,
        tokens: []const struct { position: usize, value: []const u8 },
    };
    const parsed = try std.json.parseFromSlice(Document, gpa, result.stdout, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(arguments.len + 1, parsed.value.count);
    try std.testing.expectEqual(arguments.len + 1, parsed.value.tokens.len);
    try std.testing.expect(!parsed.value.shellEvaluation);
    for (arguments, 0..) |argument, index| {
        // Length equality above is checked before any token indexing.
        try std.testing.expectEqualStrings(argument, parsed.value.tokens[index + 1].value);
        try std.testing.expectEqual(index + 1, parsed.value.tokens[index + 1].position);
    }
    try expectCompleted(fixture, request.action_id, "success");

    // A batch script is not a native executable: the executor must never
    // implicitly insert cmd.exe, even though the pinned std.spawn does.
    try fixture.workspace.writeFile(io, .{ .sub_path = "implicit.cmd", .data = "@echo shell-ran>script-ran.txt\r\n" });
    const script = try fixture.workspace.realPathFileAlloc(io, "implicit.cmd", gpa);
    defer gpa.free(script);
    var batch = fixture.request("no-implicit-shell");
    batch.program = script;
    batch.argv = &.{"\"%JCKG_M03_EXPAND%\" & echo hostile"};
    var refused = try fixture.executor().run(batch, &token);
    defer refused.deinit();
    try std.testing.expectEqual(native.Status.launch_failure, refused.status);
    try std.testing.expect(refused.exit_code == null and refused.process == null);
    try std.testing.expectError(error.FileNotFound, fixture.workspace.statFile(io, "script-ran.txt", .{}));

    // Even a fully qualified missing .exe must not become .exe.cmd through
    // ambient PATHEXT. Parent state is snapshotted and restored faithfully.
    var parent = try (std.process.Environ{ .block = .global }).createMap(gpa);
    defer parent.deinit();
    const old_pathext = if (parent.get("PATHEXT")) |value| try std.unicode.wtf8ToWtf16LeAllocZ(gpa, value) else null;
    defer if (old_pathext) |value| gpa.free(value);
    const pathext_name = std.unicode.utf8ToUtf16LeStringLiteral("PATHEXT");
    try windows.setEnvironment(pathext_name, std.unicode.utf8ToUtf16LeStringLiteral(".CMD;.EXE"));
    defer windows.setEnvironment(pathext_name, old_pathext) catch {};
    try fixture.workspace.writeFile(io, .{ .sub_path = "missing-tool.exe.cmd", .data = "@echo extension-ran>extension-ran.txt\r\n" });
    const workspace_path = try fixture.workspace.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(workspace_path);
    const missing_exact = try std.fs.path.join(gpa, &.{ workspace_path, "missing-tool.exe" });
    defer gpa.free(missing_exact);
    var exact = fixture.request("no-ambient-extension");
    exact.program = missing_exact;
    var absent = try fixture.executor().run(exact, &token);
    defer absent.deinit();
    try std.testing.expectEqual(native.Status.launch_failure, absent.status);
    try std.testing.expect(absent.exit_code == null and absent.process == null);
    try std.testing.expectError(error.FileNotFound, fixture.workspace.statFile(io, "extension-ran.txt", .{}));
}

test "m03/EXE-002 Clear ambient environment" {
    std.debug.print("JCKG_EVIDENCE EXE-002\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try windows.setEnvironment(std.unicode.utf8ToUtf16LeStringLiteral("JCKG_M03_PARENT_ONLY"), std.unicode.utf8ToUtf16LeStringLiteral("ambient-secret"));
    defer windows.setEnvironment(std.unicode.utf8ToUtf16LeStringLiteral("JCKG_M03_PARENT_ONLY"), null) catch {};
    var token: cancel.Token = .{};
    var request = fixture.request("clear-env");
    request.argv = &.{ "/d", "/c", "set" };
    request.environment = &.{.{ .name = "JCKG_DECLARED", .value = "only-declared" }};
    var result = try fixture.executor().run(request, &token);
    defer result.deinit();
    try std.testing.expectEqual(native.Status.success, result.status);
    try expectExit(result, 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "JCKG_DECLARED=only-declared") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "JCKG_M03_PARENT_ONLY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ambient-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "USERPROFILE=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "TEMP=") == null);
    // Empty declared environment also launches the installed native client.
    var empty = fixture.request("empty-env");
    empty.program = fixture.client;
    empty.argv = &.{"version"};
    var clean = try fixture.executor().run(empty, &token);
    defer clean.deinit();
    try std.testing.expectEqual(native.Status.success, clean.status);
}

test "m03/EXE-003 Collect only declared outputs" {
    std.debug.print("JCKG_EVIDENCE EXE-003\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var token: cancel.Token = .{};
    var request = fixture.request("declared-outputs");
    request.argv = &.{ "/d", "/c", "(echo declared)>declared.txt & (echo undeclared)>stray.txt & mkdir nested & (echo nested)>nested\\child.txt & mkdir nested\\empty" };
    request.outputs = &.{ "declared.txt", "nested" };
    var result = try fixture.executor().run(request, &token);
    defer result.deinit();
    try expectStatus(.success, result);
    const outputs = result.outputs orelse return error.MissingCollectedOutputs;
    try std.testing.expectEqual(@as(usize, 4), outputs.entries.len);
    try std.testing.expectEqual(@as(usize, 1), outputs.undeclared.len);
    try std.testing.expectEqualStrings("stray.txt", outputs.undeclared[0]);
    for (outputs.entries) |entry| {
        try std.testing.expect(!std.mem.eql(u8, "stray.txt", entry.path));
        if (entry.kind == .file) {
            const text = entry.digest orelse return error.MissingOutputDigest;
            const blob = try fixture.store().readBlobAlloc(gpa, try digest.Digest.parse(text));
            defer gpa.free(blob);
            try std.testing.expect(blob.len > 0);
        }
    }
    const manifest = try fixture.store().readTreeManifest(gpa, outputs.tree_digest);
    defer gpa.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "stray.txt") == null);
    const stray = try fixture.workspace.readFileAlloc(io, "stray.txt", gpa, .limited(1024));
    defer gpa.free(stray);
    try std.testing.expect(!fixture.store().hasBlob(digest.ofBlob(stray)));
}

test "m03/EXE-004 Reject output escape" {
    std.debug.print("JCKG_EVIDENCE EXE-004\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.root.createDirPath(io, "outside");
    const secret = "escaped-data-must-not-be-published";
    try fixture.root.writeFile(io, .{ .sub_path = "outside/leaked.txt", .data = secret });
    const outside = try fixture.root.realPathFileAlloc(io, "outside", gpa);
    defer gpa.free(outside);
    const command = try std.fmt.allocPrint(gpa, "(echo valid)>valid.txt & mklink /J escaped \"{s}\"", .{outside});
    defer gpa.free(command);
    var token: cancel.Token = .{};
    var request = fixture.request("reparse-output");
    request.argv = &.{ "/d", "/c", command };
    request.outputs = &.{ "valid.txt", "escaped/leaked.txt" };
    var result = try fixture.executor().run(request, &token);
    defer result.deinit();
    try expectExit(result, 0);
    try std.testing.expectEqual(native.Status.infrastructure, result.status);
    try std.testing.expectEqual(error.OutputEscape, result.cause orelse return error.MissingEscapeDiagnostic);
    try std.testing.expect(result.outputs == null);
    try std.testing.expect(!fixture.store().hasBlob(digest.ofBlob(secret)));
    const valid = try fixture.workspace.readFileAlloc(io, "valid.txt", gpa, .limited(1024));
    defer gpa.free(valid);
    // Earlier declarations are not published when a later one escapes.
    try std.testing.expect(!fixture.store().hasBlob(digest.ofBlob(valid)));
    var traversal = fixture.request("traversal-output");
    traversal.argv = &.{ "/d", "/c", "exit /b 0" };
    traversal.outputs = &.{"../outside/leaked.txt"};
    var invalid = try fixture.executor().run(traversal, &token);
    defer invalid.deinit();
    try std.testing.expectEqual(native.Status.infrastructure, invalid.status);
    try std.testing.expectEqual(error.OutputEscape, invalid.cause orelse return error.MissingTraversalDiagnostic);
    try std.testing.expect(invalid.outputs == null);
}

test "m03/EXE-005 Retain action failure" {
    std.debug.print("JCKG_EVIDENCE EXE-005\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var token: cancel.Token = .{};
    var request = fixture.request("failed-action");
    request.argv = &.{ "/d", "/c", "(echo partial)>partial.txt & exit /b 37" };
    request.outputs = &.{"partial.txt"};
    var result = try fixture.executor().run(request, &token);
    defer result.deinit();
    try std.testing.expectEqual(native.Status.action_failure, result.status);
    try expectExit(result, 37);
    try std.testing.expect(result.outputs == null);
    const partial = try fixture.workspace.readFileAlloc(io, "partial.txt", gpa, .limited(1024));
    defer gpa.free(partial);
    try std.testing.expect(!fixture.store().hasBlob(digest.ofBlob(partial)));
    try expectCompleted(fixture, request.action_id, "action_failure");
    // Full DWORD exit values must not silently truncate to Zig's u8 Term.
    var wide = fixture.request("wide-exit");
    wide.argv = &.{ "/d", "/c", "exit /b 513" };
    var wide_result = try fixture.executor().run(wide, &token);
    defer wide_result.deinit();
    try std.testing.expectEqual(native.Status.action_failure, wide_result.status);
    try expectExit(wide_result, 513);
}

test "m03/EXE-006 Distinguish launch failure" {
    std.debug.print("JCKG_EVIDENCE EXE-006\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    const missing = try std.fs.path.join(gpa, &.{ fixture.client, "missing.exe" });
    defer gpa.free(missing);
    var token: cancel.Token = .{};
    var request = fixture.request("missing-tool");
    request.program = missing;
    var result = try fixture.executor().run(request, &token);
    defer result.deinit();
    try std.testing.expectEqual(native.Status.launch_failure, result.status);
    try std.testing.expect(result.exit_code == null);
    try std.testing.expect(result.process == null);
    try std.testing.expect(result.cause != null);
    try std.testing.expect(result.outputs == null);
    try expectCompleted(fixture, request.action_id, "launch_failure");
    var bad = fixture.request("invalid-executable");
    try fixture.workspace.writeFile(io, .{ .sub_path = "not-executable.exe", .data = "not an executable" });
    const bad_path = try fixture.workspace.realPathFileAlloc(io, "not-executable.exe", gpa);
    defer gpa.free(bad_path);
    bad.program = bad_path;
    var invalid = try fixture.executor().run(bad, &token);
    defer invalid.deinit();
    try std.testing.expectEqual(native.Status.launch_failure, invalid.status);
    try std.testing.expect(invalid.exit_code == null);
}

const Observer = struct {
    journal: journal_module.Journal,
    action_id: []const u8,
    token: *cancel.Token,
    should_cancel: bool,
    done: std.atomic.Value(bool) = .init(false),
    root: ?windows.Identity = null,
    descendants: [32]windows.Identity = undefined,
    count: usize = 0,
    ready: bool = false,
    failure: ?anyerror = null,

    fn run(self: *Observer) void {
        const start = std.Io.Timestamp.now(io, .awake);
        while (!self.done.load(.acquire)) {
            const parsed = self.journal.read(self.action_id) catch {
                sleep(5 * std.time.ns_per_ms);
                if (std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds > 10 * std.time.ns_per_s) break;
                continue;
            };
            defer parsed.deinit();
            if (parsed.value.phase == .running and parsed.value.descendants.len >= 2) {
                if (parsed.value.descendants.len > self.descendants.len) {
                    self.failure = error.TooManyFixtureDescendants;
                    break;
                }
                self.root = parsed.value.process;
                self.count = parsed.value.descendants.len;
                @memcpy(self.descendants[0..self.count], parsed.value.descendants);
                self.ready = true;
                if (self.should_cancel) self.token.request();
                return;
            }
            if (std.Io.Timestamp.now(io, .awake).nanoseconds - start.nanoseconds > 10 * std.time.ns_per_s) break;
            sleep(5 * std.time.ns_per_ms);
        }
        if (self.should_cancel) self.token.request();
    }
};

fn sleep(nanoseconds: u64) void {
    std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = nanoseconds }, .clock = .awake }, io) catch {};
}

fn treeScripts(fixture: Fixture) !void {
    const child_script = try std.fmt.allocPrint(gpa, "@\"{s}\" doctor --watch --deadline-ms 60000 --json >nul 2>nul\r\n", .{fixture.client});
    defer gpa.free(child_script);
    const root_script = try std.fmt.allocPrint(gpa, "@\"{s}\" /d /c child.cmd\r\n", .{fixture.command});
    defer gpa.free(root_script);
    try fixture.workspace.writeFile(io, .{ .sub_path = "child.cmd", .data = child_script });
    try fixture.workspace.writeFile(io, .{ .sub_path = "root.cmd", .data = root_script });
}

fn expectTreeGone(observer: Observer) !void {
    try std.testing.expect(observer.failure == null);
    try std.testing.expect(observer.ready);
    try std.testing.expect(observer.count >= 2);
    try std.testing.expect(observer.count <= observer.descendants.len);
    const root = observer.root orelse return error.MissingOwnedProcess;
    try std.testing.expectEqual(windows.State.gone, windows.state(root));
    for (observer.descendants[0..observer.count]) |descendant| try std.testing.expectEqual(windows.State.gone, windows.state(descendant));
}

/// Assertions inspect process state before this defer runs. A failed cleanup
/// implementation must not leave fixture descendants behind or release the
/// disposable workspace while those processes still own it.
fn cleanupFixtureTree(observer: *const Observer) void {
    if (observer.root) |root| windows.taskkill(gpa, io, root) catch {};
    for (observer.descendants[0..@min(observer.count, observer.descendants.len)]) |descendant| windows.taskkill(gpa, io, descendant) catch {};
}

test "m03/EXE-007 Cancel descendants" {
    std.debug.print("JCKG_EVIDENCE EXE-007\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try treeScripts(fixture);
    var token: cancel.Token = .{};
    var observer: Observer = .{ .journal = fixture.journal(), .action_id = "cancel-tree", .token = &token, .should_cancel = true };
    defer cleanupFixtureTree(&observer);
    const watcher = try std.Thread.spawn(.{}, Observer.run, .{&observer});
    var request = fixture.request(observer.action_id);
    request.argv = &.{ "/d", "/c", "root.cmd" };
    var result = fixture.executor().run(request, &token) catch |run_error| {
        observer.done.store(true, .release);
        watcher.join();
        return run_error;
    };
    observer.done.store(true, .release);
    watcher.join();
    defer result.deinit();
    try expectStatus(.cancelled, result);
    try std.testing.expect(result.cleanup_complete);
    try std.testing.expect(result.outputs == null);
    try expectTreeGone(observer);
    try expectCompleted(fixture, request.action_id, "cancelled");
    // Timeout is a separate status and also owns the entire observed tree.
    var quiet: cancel.Token = .{};
    var deadline_observer: Observer = .{ .journal = fixture.journal(), .action_id = "timeout-tree", .token = &quiet, .should_cancel = false };
    defer cleanupFixtureTree(&deadline_observer);
    const deadline_watcher = try std.Thread.spawn(.{}, Observer.run, .{&deadline_observer});
    var deadline = fixture.request(deadline_observer.action_id);
    deadline.argv = &.{ "/d", "/c", "root.cmd" };
    deadline.deadline_ns = 2 * std.time.ns_per_s;
    var timed_out = fixture.executor().run(deadline, &quiet) catch |run_error| {
        deadline_observer.done.store(true, .release);
        deadline_watcher.join();
        return run_error;
    };
    deadline_observer.done.store(true, .release);
    deadline_watcher.join();
    defer timed_out.deinit();
    try std.testing.expectEqual(native.Status.timeout, timed_out.status);
    try std.testing.expect(timed_out.cleanup_complete);
    try std.testing.expect(timed_out.outputs == null);
    try expectTreeGone(deadline_observer);
    try expectCompleted(fixture, deadline.action_id, "timeout");
    var pre_cancel: cancel.Token = .{};
    pre_cancel.request();
    var pre = try fixture.executor().run(fixture.request("pre-cancel"), &pre_cancel);
    defer pre.deinit();
    try std.testing.expectEqual(native.Status.cancelled, pre.status);
    try std.testing.expect(pre.process == null);
    try std.testing.expect(pre.exit_code == null);
}

test "m03/EXE-008 Report native limitations" {
    std.debug.print("JCKG_EVIDENCE EXE-008\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    const backend = native.nativeBackend();
    try std.testing.expect(std.mem.indexOf(u8, backend.isolation_boundary, "same user") != null);
    try std.testing.expect(std.mem.indexOf(u8, backend.isolation_boundary, "no sandbox") != null);
    for ([_][]const u8{ "filesystem.isolation", "network.isolation", "resources.bounds" }) |name| {
        const capability = backend.find(name) orelse return error.MissingNativeCapability;
        try std.testing.expectEqual(capabilities.Status.unavailable, capability.status);
        try std.testing.expect(capability.blocks_release);
        try std.testing.expectError(error.CapabilityUnavailable, native.requireCapabilities(&.{name}));
    }
    try std.testing.expectError(error.CapabilityUnavailable, native.requireCapabilities(&.{"unknown.strict.capability"}));
    try std.testing.expectError(error.CapabilityUnavailable, native.requireCapabilities(&.{"process.cleanup"}));
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var token: cancel.Token = .{};
    var request = fixture.request("strict-action");
    request.argv = &.{ "/d", "/c", "(echo should-not-run)>forbidden.txt" };
    request.strict_capabilities = &.{"filesystem.isolation"};
    try std.testing.expectError(error.CapabilityUnavailable, fixture.executor().run(request, &token));
    try std.testing.expectError(error.FileNotFound, fixture.workspace.statFile(io, "forbidden.txt", .{}));
    const absent = try fixture.journal().reconcile(request.action_id);
    try std.testing.expectEqual(journal_module.ProcessState.not_started, absent.process_state);
}

test "m03/EXE-009 Bound diagnostics" {
    std.debug.print("JCKG_EVIDENCE EXE-009\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var token: cancel.Token = .{};
    var request = fixture.request("bounded-diagnostics");
    request.argv = &.{ "/d", "/c", "for /L %i in (1,1,20000) do @(echo stdout-0123456789abcdef & echo stderr-0123456789abcdef 1>&2)" };
    request.log_budget = 257;
    const started = std.Io.Timestamp.now(io, .awake);
    var result = try fixture.executor().run(request, &token);
    defer result.deinit();
    try std.testing.expectEqual(native.Status.success, result.status);
    try expectExit(result, 0);
    try std.testing.expect(result.stdout.len + result.stderr.len <= request.log_budget);
    try std.testing.expectEqual(@as(usize, 129), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 128), result.stderr.len);
    try std.testing.expect(result.stdout_discarded > 100_000);
    try std.testing.expect(result.stderr_discarded > 100_000);
    try std.testing.expectEqual(request.log_budget, result.stdout_storage.len + result.stderr_storage.len);
    try std.testing.expect(std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds < 20 * std.time.ns_per_s);
    // A zero capture budget still drains both streams and completes.
    var zero = fixture.request("zero-budget");
    zero.argv = &.{ "/d", "/c", "echo out & echo err 1>&2" };
    zero.log_budget = 0;
    var discarded = try fixture.executor().run(zero, &token);
    defer discarded.deinit();
    try std.testing.expectEqual(native.Status.success, discarded.status);
    try std.testing.expectEqual(@as(usize, 0), discarded.stdout.len + discarded.stderr.len);
    try std.testing.expect(discarded.stdout_discarded > 0 and discarded.stderr_discarded > 0);
}

test "m03/EXE-010 Reconcile controller failure" {
    std.debug.print("JCKG_EVIDENCE EXE-010\n", .{});
    if (builtin.os.tag != .windows) return expectUnavailableHost();
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var gone = try std.process.spawn(io, .{ .argv = &.{ fixture.command, "/d", "/c", "exit /b 0" }, .environ_map = &env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true });
    defer gone.kill(io);
    const gone_identity = try windows.identity(gone.id orelse return error.MissingGoneProcessHandle);
    _ = try gone.wait(io);
    try fixture.journal().record(.{ .action_id = "gone-controller", .phase = .running, .process = gone_identity });
    var live = try std.process.spawn(io, .{ .argv = &.{ fixture.client, "doctor", "--watch", "--deadline-ms", "60000", "--json" }, .environ_map = &env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true });
    defer live.kill(io);
    const live_identity = try windows.identity(live.id orelse return error.MissingLiveProcessHandle);
    try fixture.journal().record(.{ .action_id = "live-controller", .phase = .running, .process = live_identity });
    // Another controller opens the persisted directory afresh, not an in-memory
    // record list, and reconciles actual OS state before deciding to retry.
    const reopened = try fixture.root.openDir(io, "journal", .{ .iterate = true });
    defer reopened.close(io);
    const restarted: native.Executor = .{ .io = io, .gpa = gpa, .store = fixture.store(), .journal = .{ .dir = reopened, .io = io, .gpa = gpa } };
    var reconciliation = try restarted.reconcile();
    defer reconciliation.deinit();
    try std.testing.expectEqual(@as(usize, 2), reconciliation.observations.len);
    var saw_live = false;
    var saw_gone = false;
    for (reconciliation.observations) |observation| {
        if (std.mem.eql(u8, observation.action_id, "live-controller")) {
            saw_live = true;
            try std.testing.expectEqual(journal_module.ProcessState.live, observation.process_state);
            try std.testing.expect(!observation.safe_to_retry);
        } else if (std.mem.eql(u8, observation.action_id, "gone-controller")) {
            saw_gone = true;
            try std.testing.expectEqual(journal_module.ProcessState.gone, observation.process_state);
            try std.testing.expect(observation.safe_to_retry);
        }
    }
    try std.testing.expect(saw_live and saw_gone);
    var token: cancel.Token = .{};
    try std.testing.expectError(error.ActionAlreadyRunning, restarted.run(fixture.request("live-controller"), &token));
    // A PID recycled to a different creation time cannot steal old ownership.
    try fixture.journal().record(.{ .action_id = "recycled-pid", .phase = .running, .process = .{ .pid = live_identity.pid, .created = live_identity.created -| 1 } });
    const recycled = try restarted.journal.reconcile("recycled-pid");
    try std.testing.expectEqual(journal_module.ProcessState.gone, recycled.process_state);
    try std.testing.expect(recycled.safe_to_retry);
    // An interrupted pre-identity launch is uncertain, never safe to replay.
    try fixture.journal().record(.{ .action_id = "uncertain-start", .phase = .started });
    try std.testing.expectError(error.ActionStateUncertain, restarted.run(fixture.request("uncertain-start"), &token));
    live.kill(io);
    const stopped = try restarted.journal.reconcile("live-controller");
    try std.testing.expectEqual(journal_module.ProcessState.gone, stopped.process_state);
    try std.testing.expect(stopped.safe_to_retry);
    var retry = fixture.request("gone-controller");
    retry.argv = &.{ "/d", "/c", "exit /b 0" };
    var recovered = try restarted.run(retry, &token);
    defer recovered.deinit();
    try std.testing.expectEqual(native.Status.success, recovered.status);
    try expectCompleted(fixture, retry.action_id, "success");
}
