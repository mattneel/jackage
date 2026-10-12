//! Integration tests that run the real `jckg` binary (cases CLI-003, CLI-005,
//! CLI-007, CLI-009, CLI-010).
//!
//! These tests only measure what the produced executable actually does: the
//! exit code, the exact bytes on stdout and stderr, and the effect on files.
//! They require `zig build` to have installed the client first.
const std = @import("std");
const builtin = @import("builtin");

pub const client_path = if (builtin.os.tag == .windows) "zig-out/bin/jckg.exe" else "zig-out/bin/jckg";

pub const CliResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: CliResult) void {
        self.gpa.free(self.stdout);
        self.gpa.free(self.stderr);
    }

    pub fn lastStdoutLine(self: CliResult) []const u8 {
        const trimmed = std.mem.trimEnd(u8, self.stdout, "\r\n");
        const newline = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return trimmed;
        return trimmed[newline + 1 ..];
    }
};

fn requireClient(io: std.Io) !void {
    _ = std.Io.Dir.cwd().statFile(io, client_path, .{}) catch {
        std.debug.print("client not built: run `zig build` before the integration tests\n", .{});
        return error.ClientNotBuilt;
    };
}

/// Runs the client with optional stdin bytes and an optional environment.
pub fn runCli(
    io: std.Io,
    gpa: std.mem.Allocator,
    arguments: []const []const u8,
    stdin_data: ?[]const u8,
    env: ?*const std.process.Environ.Map,
) !CliResult {
    var storage: [24][]const u8 = undefined;
    storage[0] = client_path;
    var count: usize = 1;
    for (arguments) |argument| {
        if (count == storage.len) return error.TooManyArguments;
        storage[count] = argument;
        count += 1;
    }

    var child = try std.process.spawn(io, .{
        .argv = storage[0..count],
        .stdin = if (stdin_data != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = env,
        .create_no_window = true,
    });
    defer child.kill(io);

    if (stdin_data) |data| {
        if (child.stdin) |stdin_file| {
            try stdin_file.writeStreamingAll(io, data);
            stdin_file.close(io);
            // The handle is closed: clear the field so cleanup never touches it
            // again (touching it produced an INVALID_HANDLE status in the
            // process teardown path).
            child.stdin = null;
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    const stdout = try stdout_reader.interface.allocRemaining(gpa, .unlimited);
    errdefer gpa.free(stdout);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buffer);
    const stderr = try stderr_reader.interface.allocRemaining(gpa, .unlimited);
    errdefer gpa.free(stderr);

    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |value| value,
        else => 255,
    };
    return .{ .exit_code = code, .stdout = stdout, .stderr = stderr, .gpa = gpa };
}

fn expectJsonLines(gpa: std.mem.Allocator, text: []const u8) !usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        count += 1;
    }
    return count;
}

test "m01/CLI-003 separate JSON output" {
    std.debug.print("JCKG_EVIDENCE CLI-003\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireClient(io);

    // Success: every stdout line is one JSON document and no prose leaks in.
    const success = try runCli(io, gpa, &.{ "doctor", "--json" }, null, null);
    defer success.deinit();
    try std.testing.expectEqual(@as(u8, 0), success.exit_code);
    try std.testing.expectEqual(@as(usize, 1), try expectJsonLines(gpa, success.stdout));
    try std.testing.expect(std.mem.indexOf(u8, success.stdout, "doctor\n") == null);

    // Failure with structured output selected: stdout stays parseable and the
    // document carries the stable code.
    const failure = try runCli(io, gpa, &.{ "doctor", "--json", "--jsno" }, null, null);
    defer failure.deinit();
    try std.testing.expectEqual(@as(u8, 2), failure.exit_code);
    try std.testing.expectEqual(@as(usize, 1), try expectJsonLines(gpa, failure.stdout));
    try std.testing.expect(std.mem.indexOf(u8, failure.stdout, "\"code\":\"USAGE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.stdout, "unknown flag '--jsno'") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.stderr, "unknown flag '--jsno'") != null);

    // Human mode: results go to stdout as text, never as JSON.
    const human = try runCli(io, gpa, &.{"version"}, null, null);
    defer human.deinit();
    try std.testing.expectEqual(@as(u8, 0), human.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, human.stdout, "{") == null);
    try std.testing.expect(std.mem.indexOf(u8, human.stdout, "jackage 0.1.0-dev") != null);

    // Negative-or-recovery: JSON mode writes no progress text to stdout even
    // while it reports several events.
    const watched = try runCli(io, gpa, &.{ "doctor", "--json", "--watch", "--deadline-ms", "0" }, null, null);
    defer watched.deinit();
    try std.testing.expectEqual(@as(u8, 0), watched.exit_code);
    try std.testing.expect(try expectJsonLines(gpa, watched.stdout) >= 1);
}

test "m01/CLI-005 preserve argument boundaries" {
    std.debug.print("JCKG_EVIDENCE CLI-005\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireClient(io);

    // Hostile-looking arguments: spaces, quotes, shell metacharacters, percent
    // expansion, Unicode, and flag lookalikes after the separator.
    const expected = [_][]const u8{
        "a b",
        "quote\"inside",
        "semi;colon",
        "$(echo pwned)",
        "`backtick`",
        "%PATH%",
        "ünïcödé-路径",
        "--flag-looking",
        "-x",
        "trailing\\",
    };
    var arguments: [3 + expected.len][]const u8 = undefined;
    arguments[0] = "echo";
    arguments[1] = "--json";
    arguments[2] = "--";
    for (expected, 0..) |value, index| arguments[3 + index] = value;

    const result = try runCli(io, gpa, &arguments, null, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, result.lastStdoutLine(), .{});
    defer parsed.deinit();
    const document = parsed.value;
    try std.testing.expectEqualStrings("argv", document.object.get("kind").?.string);
    try std.testing.expect(!document.object.get("shellEvaluation").?.bool);
    const tokens = document.object.get("tokens").?.array;
    // Token 0 is the program name; the rest must match byte for byte.
    try std.testing.expectEqual(expected.len + 1, tokens.items.len);
    for (expected, 0..) |value, index| {
        const token = tokens.items[index + 1];
        try std.testing.expectEqualStrings(value, token.object.get("value").?.string);
        try std.testing.expectEqualStrings("passthrough", token.object.get("origin").?.string);
    }

    // Negative-or-recovery: a token that looks like a flag is still passed
    // through, and a same-length argument is not confused with its neighbour.
    const single = try runCli(io, gpa, &.{ "echo", "--json", "--", "a b" }, null, null);
    defer single.deinit();
    var parsed_single = try std.json.parseFromSlice(std.json.Value, gpa, single.lastStdoutLine(), .{});
    defer parsed_single.deinit();
    const single_tokens = parsed_single.value.object.get("tokens").?.array;
    try std.testing.expectEqual(@as(usize, 2), single_tokens.items.len);
    try std.testing.expectEqualStrings("a b", single_tokens.items[1].object.get("value").?.string);
}

fn uniqueWorkDirectory(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    return gpa.print(".zig-cache/jckg-it-{s}", .{suffix});
}

test "m01/CLI-007 initialize safely" {
    std.debug.print("JCKG_EVIDENCE CLI-007\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireClient(io);

    const directory = try uniqueWorkDirectory(gpa, io);
    defer gpa.free(directory);
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const declaration_path = try std.fs.path.join(gpa, &.{ directory, "jackage.ts" });
    defer gpa.free(declaration_path);

    // First run creates the declaration.
    const created = try runCli(io, gpa, &.{ "init", "--directory", directory, "--json" }, null, null);
    defer created.deinit();
    try std.testing.expectEqual(@as(u8, 0), created.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, created.stdout, "\"status\":\"created\"") != null);
    const original = try std.Io.Dir.cwd().readFileAlloc(io, declaration_path, gpa, .unlimited);
    defer gpa.free(original);
    try std.testing.expect(std.mem.indexOf(u8, original, "defineProject") != null);

    // Second run reports the conflict and changes nothing.
    const conflicted = try runCli(io, gpa, &.{ "init", "--directory", directory, "--json" }, null, null);
    defer conflicted.deinit();
    try std.testing.expectEqual(@as(u8, 3), conflicted.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, conflicted.stdout, "\"status\":\"conflict\"") != null);
    const after_conflict = try std.Io.Dir.cwd().readFileAlloc(io, declaration_path, gpa, .unlimited);
    defer gpa.free(after_conflict);
    try std.testing.expectEqualStrings(original, after_conflict);

    // --force without an approval and without a terminal is refused, and the
    // file still does not change.
    const refused = try runCli(io, gpa, &.{ "init", "--directory", directory, "--force" }, null, null);
    defer refused.deinit();
    try std.testing.expectEqual(@as(u8, 3), refused.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, refused.stderr, "--yes") != null);
    const after_refusal = try std.Io.Dir.cwd().readFileAlloc(io, declaration_path, gpa, .unlimited);
    defer gpa.free(after_refusal);
    try std.testing.expectEqualStrings(original, after_refusal);

    // An authorized replacement does change the file, and only then.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = declaration_path, .data = "replaced by the test\n" });
    const replaced = try runCli(io, gpa, &.{ "init", "--directory", directory, "--force", "--yes", "--json" }, null, null);
    defer replaced.deinit();
    try std.testing.expectEqual(@as(u8, 0), replaced.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, replaced.stdout, "\"status\":\"replaced\"") != null);
    const after_replace = try std.Io.Dir.cwd().readFileAlloc(io, declaration_path, gpa, .unlimited);
    defer gpa.free(after_replace);
    try std.testing.expect(std.mem.indexOf(u8, after_replace, "defineProject") != null);
    try std.testing.expectEqualStrings(original, after_replace);

    // Negative-or-recovery: an unknown flag leaves no file behind at all.
    const other_directory = try uniqueWorkDirectory(gpa, io);
    defer gpa.free(other_directory);
    defer std.Io.Dir.cwd().deleteTree(io, other_directory) catch {};
    try std.Io.Dir.cwd().createDirPath(io, other_directory);
    const untouched_path = try std.fs.path.join(gpa, &.{ other_directory, "jackage.ts" });
    defer gpa.free(untouched_path);
    const bad = try runCli(io, gpa, &.{ "init", "--directory", other_directory, "--overwrite" }, null, null);
    defer bad.deinit();
    try std.testing.expectEqual(@as(u8, 2), bad.exit_code);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, untouched_path, .{}));
}

test "m01/CLI-009 respect cancellation" {
    std.debug.print("JCKG_EVIDENCE CLI-009\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireClient(io);

    // A long watch is started and cancelled through the documented stdin
    // trigger; the client must stop cleanly, report the cancellation, and
    // return the documented code well before its deadline.
    const started = std.Io.Timestamp.now(io, .awake);
    const result = try runCli(
        io,
        gpa,
        &.{ "doctor", "--json", "--watch", "--cancel-on-stdin", "--deadline-ms", "60000" },
        "c\n",
        null,
    );
    defer result.deinit();
    const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds;

    try std.testing.expectEqual(@as(u8, 130), result.exit_code);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, result.lastStdoutLine(), .{});
    defer parsed.deinit();
    const summary = parsed.value;
    try std.testing.expectEqualStrings("summary", summary.object.get("kind").?.string);
    try std.testing.expectEqualStrings("canceled", summary.object.get("status").?.string);
    try std.testing.expectEqualStrings("stdin", summary.object.get("stopReason").?.string);
    // Cancellation was honored long before the 60 second deadline.
    try std.testing.expect(elapsed < 30 * std.time.ns_per_s);

    // Negative-or-recovery: without the trigger the same command is bounded by
    // its deadline and completes successfully instead of being cancelled.
    const bounded = try runCli(io, gpa, &.{ "doctor", "--json", "--watch", "--deadline-ms", "0" }, null, null);
    defer bounded.deinit();
    try std.testing.expectEqual(@as(u8, 0), bounded.exit_code);
    var bounded_parsed = try std.json.parseFromSlice(std.json.Value, gpa, bounded.lastStdoutLine(), .{});
    defer bounded_parsed.deinit();
    try std.testing.expectEqualStrings("completed", bounded_parsed.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("deadline", bounded_parsed.value.object.get("stopReason").?.string);
}

test "m01/CLI-010 keep secrets out of errors" {
    std.debug.print("JCKG_EVIDENCE CLI-010\n", .{});
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try requireClient(io);

    const url_secret = "ghp_zzzzzzzzzzzzzzzzzzzzzzzz";
    const env_secret = "ghp_abcdefghijklmnopqrstuvwx";
    const url = "https://octocat:" ++ url_secret ++ "@example.invalid/org/repo.git";

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("JCKG_TEST_TOKEN", env_secret);
    try env.put("SystemRoot", "C:\\Windows");

    // A successful command that receives a credential-bearing locator.
    const ok = try runCli(io, gpa, &.{ "doctor", "--json", "--repo", url }, null, &env);
    defer ok.deinit();
    try std.testing.expectEqual(@as(u8, 0), ok.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, ok.stdout, url_secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, ok.stderr, url_secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, ok.stdout, env_secret) == null);
    // The host stays visible so the diagnostic is still useful.
    try std.testing.expect(std.mem.indexOf(u8, ok.stdout, "***@example.invalid/org/repo.git") != null);

    // A failing boundary with the same input: usage error.
    const failing = try runCli(io, gpa, &.{ "doctor", "--json", "--repo", url, "--nope" }, null, &env);
    defer failing.deinit();
    try std.testing.expectEqual(@as(u8, 2), failing.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, failing.stdout, url_secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, failing.stderr, url_secret) == null);

    // And the policy boundary: an unauthorized replacement is refused, and the
    // refusal still carries no credential.
    const directory = try uniqueWorkDirectory(gpa, io);
    defer gpa.free(directory);
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const declaration_path = try std.fs.path.join(gpa, &.{ directory, "jackage.ts" });
    defer gpa.free(declaration_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = declaration_path, .data = "// existing declaration\n" });

    const denied = try runCli(io, gpa, &.{ "init", "--force", "--json", "--directory", directory }, null, &env);
    defer denied.deinit();
    try std.testing.expectEqual(@as(u8, 3), denied.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, denied.stdout, env_secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, denied.stderr, env_secret) == null);
    const after = try std.Io.Dir.cwd().readFileAlloc(io, declaration_path, gpa, .unlimited);
    defer gpa.free(after);
    try std.testing.expectEqualStrings("// existing declaration\n", after);
}
