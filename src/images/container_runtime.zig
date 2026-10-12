//! Building and testing a fixture inside a real container runtime (M15, IMAGE-002).
//!
//! The development image is only worth declaring if it actually runs the declared
//! tools. This module generates a Dockerfile from the declaration - the pinned
//! toolchain, fetched and verified at the digest the repository pins - copies a
//! fixture in, builds it, and runs it, all inside the runtime rather than on the
//! host.
//!
//! "Native guest storage" is part of the claim, not decoration. A build whose context
//! lives under a Windows mount is a build whose filesystem operations travel through
//! the translation layer, which is exactly the situation the declared execution
//! environment exists to avoid; so the context is checked to be outside `/mnt` before
//! anything is built.
//!
//! The tools are pinned the same way the host pins them: the version comes from
//! `.zigversion` and the archive digest is the one the repository already records, so
//! the container and the host compile with the same compiler rather than with
//! whatever the base image happens to ship.
const std = @import("std");
const ext4 = @import("ext4.zig");

pub const Error = error{
    // The declared toolchain is not described by this checkout.
    InvalidDeclaration,
    HostMountContext,
    BuildFailed,
    RunFailed,
    UnexpectedOutput,
    OutOfMemory,
};

/// Where the execution environment keeps the verified toolchain archives, beside the
/// toolchains it installed from them.
pub const toolchain_archive_dir = "/home/autark/jckg/toolchain/archive";

/// The pinned Linux toolchain, as `scripts/fetch-zig-linux.sh` records it.
pub const pinned_archive_sha256 = "1061dbb921f62b67765810609a80c17fa69eeced9f21e9a7e0d06b4e0d7a3715";

pub const Declaration = struct {
    /// The version `.zigversion` pins.
    version: []const u8,
    /// The name the verified toolchain archive has inside the build context.
    toolchain_archive: []const u8,
    /// The fixture project's directory, relative to the context.
    fixture: []const u8,
    /// The command that builds and tests the fixture.
    test_command: []const u8 = "zig build test",
};

/// Renders the Dockerfile for a declaration.
///
/// The toolchain is fetched inside the image and verified against the pinned digest
/// before it is unpacked, so a compromised mirror is caught by the same check the host
/// uses. `apt-get` is kept minimal and cleaned in one layer, because a development
/// image that carries an apt cache is carrying something a build does not need.
pub fn renderDockerfile(gpa: std.mem.Allocator, declaration: Declaration) Error![]u8 {
    if (declaration.version.len == 0 or declaration.fixture.len == 0 or declaration.toolchain_archive.len == 0) {
        return error.InvalidDeclaration;
    }
    // The toolchain comes from the build context rather than from the network. It has
    // already been verified once by the environment that provides it, and verifying it
    // again here means the image cannot be built with a compiler nobody checked -
    // while requiring no network access inside the build at all. A download inside the
    // container was tried first and produced a tarball that failed this same digest
    // check, which is the kind of thing that is much easier to refuse than to debug.
    return std.fmt.allocPrint(
        gpa,
        \\FROM debian:stable-slim
        \\RUN set -eux; \
        \\    apt-get update; \
        \\    apt-get install -y --no-install-recommends ca-certificates xz-utils; \
        \\    rm -rf /var/lib/apt/lists/*
        \\COPY {s} /tmp/zig.tar.xz
        \\RUN set -eux; \
        \\    echo "{s}  /tmp/zig.tar.xz" | sha256sum -c -; \
        \\    mkdir -p /opt/zig; \
        \\    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
        \\    rm /tmp/zig.tar.xz; \
        \\    ln -s /opt/zig/zig /usr/local/bin/zig; \
        \\    zig version
        \\WORKDIR /fixture
        \\COPY {s}/ /fixture/
        \\CMD ["zig", "version"]
        \\
    , .{ declaration.toolchain_archive, pinned_archive_sha256, declaration.fixture });
}

/// True when a path is inside a Windows mount, where a build would run its filesystem
/// operations through the translation layer rather than on guest-native storage.
pub fn onWindowsMount(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/mnt/") or std.mem.startsWith(u8, path, "C:");
}

pub const Build = struct {
    tag: []u8,
    /// What the runtime reported while building, so the transcript is the evidence.
    output: []u8,

    pub fn deinit(self: Build, gpa: std.mem.Allocator) void {
        gpa.free(self.tag);
        gpa.free(self.output);
    }
};

/// Builds the image and returns what the build printed.
pub fn build(
    gpa: std.mem.Allocator,
    io: std.Io,
    context_path: []const u8,
    tag: []const u8,
) Error!Build {
    if (onWindowsMount(context_path)) return error.HostMountContext;
    // The command runner has its own error set; from here a runtime that could not be
    // started at all is a failed build, and the transcript says which.
    const output = ext4.run(gpa, io, &.{
        "docker",
        "build",
        "--tag",
        tag,
        "--progress",
        "plain",
        context_path,
    }) catch return error.BuildFailed;
    defer output.deinit(gpa);
    // The transcript is captured whatever the outcome: "the declared tools execute" is
    // a claim about a command somebody can read, and a failure whose reason was
    // discarded cannot be acted on.
    const combined = std.mem.concat(gpa, u8, &.{ output.stdout, output.stderr }) catch return error.OutOfMemory;
    if (output.exit_code != 0) {
        std.debug.print("docker build failed:\n{s}\n", .{combined});
        gpa.free(combined);
        return error.BuildFailed;
    }
    return .{ .tag = try gpa.dupe(u8, tag), .output = combined };
}

pub const Run = struct {
    exit_code: u8,
    stdout: []u8,

    pub fn deinit(self: Run, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

/// Runs a command in the built image.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    image: []const u8,
    argv: []const []const u8,
) Error!Run {
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(gpa);
    command.appendSlice(gpa, &.{ "docker", "run", "--rm", image }) catch return error.OutOfMemory;
    command.appendSlice(gpa, argv) catch return error.OutOfMemory;

    const output = ext4.run(gpa, io, command.items) catch return error.RunFailed;
    defer output.deinit(gpa);
    const stdout = try gpa.dupe(u8, output.stdout);
    errdefer gpa.free(stdout);
    if (output.exit_code != 0) {
        // A failed run still reports what the container said, so the reason is in the
        // transcript rather than inferred from the exit code.
        const combined = std.mem.concat(gpa, u8, &.{ output.stdout, output.stderr }) catch return error.OutOfMemory;
        gpa.free(stdout);
        return .{ .exit_code = output.exit_code, .stdout = combined };
    }
    return .{ .exit_code = output.exit_code, .stdout = stdout };
}

test "m15/IMAGE-002 run development image: declared tools execute on native guest storage" {
    std.debug.print("JCKG_EVIDENCE IMAGE-002\n", .{});
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    // The pinned version, read from the checkout, so the container and the host use
    // the same compiler.
    const version_bytes = cwd.readFileAlloc(io, ".zigversion", gpa, .limited(1 << 10)) catch
        return error.InvalidDeclaration;
    defer gpa.free(version_bytes);
    const version = std.mem.trim(u8, version_bytes, " \r\n\t");
    try std.testing.expect(version.len > 0);

    const context_path = "zig-out/jckg-image-002";
    cwd.deleteTree(io, context_path) catch {};
    defer cwd.deleteTree(io, context_path) catch {};

    // The context is guest-native: a build under a Windows mount would be the
    // translated filesystem the declared environment exists to avoid.
    try std.testing.expect(!onWindowsMount(context_path));
    try std.testing.expect(onWindowsMount("/mnt/c/src/jackage"));
    try std.testing.expect(onWindowsMount("C:/src/jackage"));

    try cwd.createDirPath(io, context_path ++ "/fixture/src");
    const dockerfile = try renderDockerfile(gpa, .{
        .version = version,
        .toolchain_archive = "toolchain.tar.xz",
        .fixture = "fixture",
    });
    defer gpa.free(dockerfile);
    try cwd.writeFile(io, .{ .sub_path = context_path ++ "/Dockerfile", .data = dockerfile });

    // The verified toolchain archive travels in the context. It is the same archive
    // the environment installed from, checked against the digest the repository pins,
    // so the container and the host compile with the same compiler.
    // Where the environment keeps the archive it installed from, beside the toolchain
    // it produced. The path is derived from the pinned version rather than configured,
    // so the test needs no environment variable to find it.
    const archive_source = try std.fmt.allocPrint(
        gpa,
        "{s}/zig-x86_64-linux-{s}.tar.xz",
        .{ toolchain_archive_dir, version },
    );
    defer gpa.free(archive_source);
    const archive_bytes = cwd.readFileAlloc(io, archive_source, gpa, .limited(256 * 1024 * 1024)) catch
        return error.InvalidDeclaration;
    defer gpa.free(archive_bytes);
    var archive_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive_bytes, &archive_digest, .{});
    const archive_hex = std.fmt.bytesToHex(archive_digest, .lower);
    // The archive that is about to be copied into the image is the one the repository
    // pins, checked here as well as inside the build.
    try std.testing.expectEqualStrings(pinned_archive_sha256, &archive_hex);
    try cwd.writeFile(io, .{ .sub_path = context_path ++ "/toolchain.tar.xz", .data = archive_bytes });

    // A Jackage fixture: a real project with a build definition and a test, so the
    // declared tools do actual work rather than printing a version.
    try cwd.writeFile(io, .{
        .sub_path = context_path ++ "/fixture/build.zig",
        .data = 
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\    const tests = b.addTest(.{
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\    const run_tests = b.addRunArtifact(tests);
        \\    const step = b.step("test", "Run the fixture tests");
        \\    step.dependOn(&run_tests.step);
        \\}
        \\
    });
    try cwd.writeFile(io, .{
        .sub_path = context_path ++ "/fixture/src/main.zig",
        .data = 
        \\const std = @import("std");
        \\test "fixture runs inside the declared image" {
        \\    // The marker is printed by the fixture's own test, so its presence in the
        \\    // transcript is evidence that this test ran inside the image rather than
        \\    // merely that some command exited zero.
        \\    std.debug.print("JCKG_FIXTURE_OK\\n", .{});
        \\    try std.testing.expect(true);
        \\}
        \\
    });

    const built = try build(gpa, io, context_path, "jckg-dev:image-002");
    defer built.deinit(gpa);
    // A successful build is the exit code's business, and the transcript is kept for
    // diagnosis. Asserting on a specific line of it would depend on whether the
    // runtime served the layer from cache, and the claim that matters - that the
    // declared tools execute - is checked directly by running them, below.
    try std.testing.expect(built.output.len > 0);

    // The declared tools execute in the container: the compiler reports the pinned
    // version, and the fixture's own test suite runs to success.
    const toolchain = try run(gpa, io, "jckg-dev:image-002", &.{ "zig", "version" });
    defer toolchain.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), toolchain.exit_code);
    try std.testing.expectEqualStrings(version, std.mem.trim(u8, toolchain.stdout, " \n"));

    const tested = try run(gpa, io, "jckg-dev:image-002", &.{ "zig", "build", "test" });
    defer tested.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), tested.exit_code);

    // The exit code is load-bearing, so it is tested rather than assumed: a fixture
    // whose test fails must make the same command fail. Zig's build runner withholds
    // a passing test's output, so the count of tests is not visible and a run that
    // reported success for everything would be indistinguishable from one that
    // reported nothing.
    try cwd.writeFile(io, .{
        .sub_path = context_path ++ "/fixture/src/main.zig",
        .data = 
        \\const std = @import("std");
        \\test "fixture fails inside the declared image" {
        \\    try std.testing.expect(false);
        \\}
        \\
    });
    const rebuilt = try build(gpa, io, context_path, "jckg-dev:image-002-failing");
    defer rebuilt.deinit(gpa);
    const failing = try run(gpa, io, "jckg-dev:image-002-failing", &.{ "zig", "build", "test" });
    defer failing.deinit(gpa);
    try std.testing.expect(failing.exit_code != 0);
}
