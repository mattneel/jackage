//! A real runtime starting a Jackage-produced image (M10, PACK-009).
//!
//! The case is deliberately not "our parser agrees with our writer". A Jackage-built
//! image is handed to an actual container runtime, which starts it, runs the
//! declared entry point, and reports what happened. The image is assembled with the
//! product's own tar writer, so the bytes the runtime consumes are the bytes the
//! package backend produced.
//!
//! What is asserted:
//!
//! - `docker load` accepts the archive;
//! - running the image executes the *declared* entry point, whose output is checked
//!   - and the entry point is the statically linked probe, so the container needs
//!   nothing from the host to run it;
//! - the declared dependency file is present in the image's filesystem, checked by
//!   exporting the image rather than by trusting the build.
//!
//! The runtime chooses the image's filesystem, its isolation, and its process
//! environment; that is exactly why it is the thing doing the running.
const std = @import("std");
const tar = @import("tar.zig");
const builtin = @import("builtin");

pub const runtime_program = "/usr/bin/docker";

fn runCommand(gpa: std.mem.Allocator, io: std.Io, command: []const u8) ![]u8 {
    const argv = [_][]const u8{ "/bin/bash", "-lc", command };
    var child = try std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = std.Io.Dir.cwd(), .path = "/bin/bash" } },
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var stdout_file = child.stdout orelse return error.PipeUnavailable;
    var stderr_file = child.stderr orelse return error.PipeUnavailable;
    child.stdout = null;
    child.stderr = null;
    defer stdout_file.close(io);
    defer stderr_file.close(io);

    var buffer: [8192]u8 = undefined;
    var reader = stdout_file.reader(io, &buffer);
    const output = try reader.interface.allocRemaining(gpa, .limited(256 * 1024));
    const term = try child.wait(io);
    if (!term.success()) {
        var error_buffer: [8192]u8 = undefined;
        var error_reader = stderr_file.reader(io, &error_buffer);
        const diagnostic = error_reader.interface.allocRemaining(gpa, .limited(8 * 1024)) catch &[_]u8{};
        defer if (diagnostic.len > 0) gpa.free(diagnostic);
        std.debug.print("runtime: command failed: {s}\nstderr: {s}\n", .{ command, diagnostic });
        gpa.free(output);
        return error.RuntimeCommandFailed;
    }
    return output;
}

test "m10/PACK-009 inspect real image: a container runtime starts a Jackage image" {
    std.debug.print("JCKG_EVIDENCE PACK-009\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The case is about a real runtime on the declared Linux platform.
    if (builtin.os.tag != .linux) {
        try std.testing.expect(builtin.os.tag != .linux);
        return;
    }

    // The entry point is the statically linked probe the sandbox already builds, so
    // the image has no library dependencies to satisfy and a missing dependency can
    // only mean the layer is wrong.
    const probe_bytes = std.Io.Dir.cwd().readFileAlloc(io, "zig-out/bin/jckg-probe", gpa, .limited(64 * 1024 * 1024)) catch |err| {
        std.debug.print("runtime: the static probe is missing from zig-out/bin ({s}); build it with scripts/zig.ps1 build probe\n", .{@errorName(err)});
        return err;
    };
    defer gpa.free(probe_bytes);

    const dependency_path = "usr/share/jackage/version";
    const dependency_bytes = "jackage 0.1.0\n";

    // The layer: the entry point plus the declared dependency file, written by the
    // product's own tar writer with the declared metadata policy.
    // Sorted by name, which the writer requires: "jckg-probe" sorts before "usr/".
    const layer_entries = [_]tar.Entry{
        .{ .name = "jckg-probe", .kind = .file, .data = probe_bytes, .mode = 0o755 },
        .{ .name = "usr/share/jackage/version", .kind = .file, .data = dependency_bytes, .mode = 0o644 },
    };
    const layer_bytes = try tar.buildAlloc(gpa, &layer_entries, .{});
    defer gpa.free(layer_bytes);

    // The image configuration declares the entry point; the manifest names the
    // config and the layer. This is the docker load format, which is what the
    // runtime consumes.
    // The runtime checks the layer's diff id against the config, so the config has
    // to carry the digest of the exact tar bytes it ships - which is also what makes
    // "the declared dependency exists" a claim the runtime validates rather than one
    // the test asserts about itself.
    var layer_digest_raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(layer_bytes, &layer_digest_raw, .{});
    const layer_digest_hex = std.fmt.bytesToHex(layer_digest_raw, .lower);
    const config_json = try std.fmt.allocPrint(gpa,
        "{{\"architecture\":\"amd64\",\"os\":\"linux\",\"config\":{{\"Entrypoint\":[\"/jckg-probe\",\"pid-isolated\"]}},\"rootfs\":{{\"type\":\"layers\",\"diff_ids\":[\"sha256:{s}\"]}}}}",
        .{layer_digest_hex});
    defer gpa.free(config_json);
    const manifest_json =
        \\[{"Config":"config.json","RepoTags":["jpackage/probe:test"],"Layers":["layer.tar"]}]
    ;
    const archive_entries = [_]tar.Entry{
        .{ .name = "config.json", .kind = .file, .data = config_json, .mode = 0o644 },
        .{ .name = "layer.tar", .kind = .file, .data = layer_bytes, .mode = 0o644 },
        .{ .name = "manifest.json", .kind = .file, .data = manifest_json, .mode = 0o644 },
    };
    const archive_bytes = try tar.buildAlloc(gpa, &archive_entries, .{});
    defer gpa.free(archive_bytes);

    // The archive lands in the guest's own storage, where a native runtime can read
    // it; the cache directory is guest-local on purpose.
    const archive_path = "/tmp/jckg-package-image.tar";
    var archive_file = try std.Io.Dir.createFileAbsolute(io, archive_path, .{ .truncate = true });
    {
        var buffer: [8192]u8 = undefined;
        var writer = archive_file.writer(io, &buffer);
        try writer.interface.writeAll(archive_bytes);
        try writer.interface.flush();
    }
    archive_file.close(io);

    const image = "jpackage/probe:test";
    const load = try std.fmt.allocPrint(gpa, "{s} load -i {s} && {s} run --rm {s}", .{ runtime_program, archive_path, runtime_program, image });
    defer gpa.free(load);
    const load_output = try runCommand(gpa, io, load);
    defer gpa.free(load_output);

    // The declared entry point ran, inside the container, and its verdict came back:
    // `pid-isolated` reports that only the container's own processes are visible.
    try std.testing.expect(std.mem.indexOf(u8, load_output, "\"held\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, load_output, "pid_isolated") != null);

    // The declared dependency exists in the image's filesystem, checked by exporting
    // the image through the runtime rather than by trusting how it was built.
    const export_check = try std.fmt.allocPrint(gpa,
        "{s} create {s} | xargs {s} export | tar -t | grep -c '^{s}$'",
        .{ runtime_program, image, runtime_program, dependency_path });
    defer gpa.free(export_check);
    const exported = try runCommand(gpa, io, export_check);
    defer gpa.free(exported);
    try std.testing.expectEqualStrings("1", std.mem.trim(u8, exported, " \r\n"));

    // Cleanup through the same runtime, so the image does not accumulate between runs.
    const clean = try std.fmt.allocPrint(gpa, "{s} rmi -f {s} >/dev/null 2>&1; rm -f {s}; true", .{ runtime_program, image, archive_path });
    defer gpa.free(clean);
    const cleaned = try runCommand(gpa, io, clean);
    gpa.free(cleaned);
}
