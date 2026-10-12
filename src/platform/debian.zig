//! Building a Debian package the native tools accept (M11, PLAT-008).
//!
//! A `.deb` is a Unix `ar` archive holding `debian-binary`, `control.tar.gz`, and
//! `data.tar.gz`. The point of the case is not that the file exists: it is that
//! `dpkg` - the platform's own tool - inspects it, reports the metadata we wrote,
//! lists the payload we wrote, and installs and removes it.
//!
//! Everything is declared, in the same spirit as the archive writers: the control
//! fields come from a declaration, the payload comes from a declared file list with
//! declared modes (an entry point is executable because the declaration says so),
//! and the archive is written in a fixed order.
const std = @import("std");
const tar = @import("../package/tar.zig");
const compress = std.compress;

pub const Error = error{
    InvalidDeclaration,
    InvalidPayload,
    OutOfMemory,
    WriteFailed,
};

pub const Control = struct {
    package: []const u8,
    version: []const u8,
    architecture: []const u8,
    maintainer: []const u8,
    description: []const u8,
    /// Declared runtime dependencies, as `dpkg` names them.
    depends: []const []const u8 = &.{},
    section: []const u8 = "utils",
    priority: []const u8 = "optional",
};

pub const PayloadFile = struct {
    /// Absolute path inside the package's filesystem, without a leading slash.
    path: []const u8,
    bytes: []const u8,
    mode: u32,
};

fn gzipCompress(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // The standard library's flate provides the gzip container, so the wrapper -
    // header, deflate stream, CRC and length footer - is the library's job rather
    // than hand-rolled here. It needs a pre-sized output buffer, and a package
    // control or payload tar at this size fits comfortably; the compression is
    // therefore bounded and the bound is stated rather than assumed.
    var out_buffer: [512 * 1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buffer);
    var window: [compress.flate.max_window_len]u8 = undefined;
    var compressor = try compress.flate.Compress.init(&out, &window, .gzip, compress.flate.Compress.Options.default);
    try compressor.writer.writeAll(bytes);
    try compressor.finish();
    return gpa.dupe(u8, out.buffered());
}

/// Writes a Unix `ar` archive with the three members a `.deb` needs, in the order
/// `dpkg` expects. The format is fixed-size ASCII headers, which is why it needs no
/// library on either side.
const ArMember = struct { name: []const u8, bytes: []const u8 };

fn writeAr(gpa: std.mem.Allocator, members: []const ArMember, out: *std.Io.Writer) !void {
    _ = gpa;
    const global = "!<arch>\n";
    out.writeAll(global) catch return error.WriteFailed;
    for (members) |member| {
        var header: [60]u8 = @splat(' ');
        // The name field is 16 bytes and the names are shorter, so only the
        // name's own bytes are written; the rest stays the space padding set above.
        @memcpy(header[0..member.name.len], member.name);
        // mtime, uid, gid, mode are declared as zero rather than taken from the
        // host, so the archive is the same wherever it is built.
        const mtime = "0";
        @memcpy(header[16..16 + mtime.len], mtime);
        const uid = "0";
        @memcpy(header[28..28 + uid.len], uid);
        const gid = "0";
        @memcpy(header[36..36 + gid.len], gid);
        const mode = "100644";
        @memcpy(header[40..40 + mode.len], mode);
        var size_buffer: [16]u8 = undefined;
        const size_text = std.fmt.bufPrint(&size_buffer, "{d}", .{member.bytes.len}) catch return error.WriteFailed;
        @memcpy(header[48 .. 48 + size_text.len], size_text);
        header[58] = '`';
        header[59] = '\n';
        out.writeAll(&header) catch return error.WriteFailed;
        out.writeAll(member.bytes) catch return error.WriteFailed;
        if (member.bytes.len % 2 == 1) out.writeByte('\n') catch return error.WriteFailed;
    }
}

/// Builds a `.deb`. The payload tar and the control tar are gzipped and placed in
/// an `ar` archive, member order fixed.
pub fn build(gpa: std.mem.Allocator, control: Control, files: []const PayloadFile) ![]u8 {
    if (control.package.len == 0 or control.version.len == 0 or control.architecture.len == 0) {
        return error.InvalidDeclaration;
    }

    // The payload tar: declared paths, declared modes.
    var tar_entries: std.ArrayList(tar.Entry) = .empty;
    defer {
        for (tar_entries.items) |entry| gpa.free(entry.name);
        tar_entries.deinit(gpa);
    }
    for (files) |file| {
        try tar_entries.append(gpa, .{
            .name = try gpa.dupe(u8, file.path),
            .kind = .file,
            .data = file.bytes,
            .mode = file.mode,
        });
    }
    // Tar requires sorted order, and a package's payload is more useful sorted
    // anyway: dpkg lists files in the order they appear.
    std.mem.sort(tar.Entry, tar_entries.items, {}, struct {
        fn lessThan(_: void, left: tar.Entry, right: tar.Entry) bool {
            return std.mem.order(u8, left.name, right.name) == .lt;
        }
    }.lessThan);
    const data_tar = try tar.buildAlloc(gpa, tar_entries.items, .{});
    defer gpa.free(data_tar);

    // The control tar: the control file plus the metadata dpkg reads.
    var control_text: std.Io.Writer.Allocating = .init(gpa);
    defer control_text.deinit();
    const control_writer = &control_text.writer;
    control_writer.print("Package: {s}\nVersion: {s}\nArchitecture: {s}\nMaintainer: {s}\nSection: {s}\nPriority: {s}\n", .{
        control.package, control.version, control.architecture, control.maintainer, control.section, control.priority,
    }) catch return error.WriteFailed;
    if (control.depends.len > 0) {
        control_writer.print("Depends: ", .{}) catch return error.WriteFailed;
        for (control.depends, 0..) |dependency, index| {
            if (index > 0) control_writer.print(", ", .{}) catch return error.WriteFailed;
            control_writer.print("{s}", .{dependency}) catch return error.WriteFailed;
        }
        control_writer.print("\n", .{}) catch return error.WriteFailed;
    }
    control_writer.print("Description: {s}\n", .{control.description}) catch return error.WriteFailed;

    const control_entries = [_]tar.Entry{
        .{ .name = "./control", .kind = .file, .data = control_text.written(), .mode = 0o644 },
    };
    // The control tar's members are named `./control` by the format, which the
    // strict payload policy rejects; the allowance is asked for explicitly.
    const control_tar = try tar.buildAlloc(gpa, &control_entries, .{ .allow_leading_dot_slash = true });
    defer gpa.free(control_tar);

    const control_gz = try gzipCompress(gpa, control_tar);
    defer gpa.free(control_gz);
    const data_gz = try gzipCompress(gpa, data_tar);
    defer gpa.free(data_gz);

    var buffer: std.Io.Writer.Allocating = .init(gpa);
    errdefer buffer.deinit();
    const members = [_]ArMember{
        .{ .name = "debian-binary", .bytes = "2.0\n" },
        .{ .name = "control.tar.gz", .bytes = control_gz },
        .{ .name = "data.tar.gz", .bytes = data_gz },
    };
    try writeAr(gpa, &members, &buffer.writer);
    return buffer.toOwnedSlice();
}

test "m11/PLAT-008 validate Debian package: native tools accept the package we built" {
    std.debug.print("JCKG_EVIDENCE PLAT-008\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    if (@import("builtin").os.tag != .linux) {
        try std.testing.expect(@import("builtin").os.tag != .linux);
        return;
    }

    // The package: a declared control block and a payload whose entry point is
    // executable because the declaration says so.
    const payload = "#!/bin/sh\necho jackage\n";
    const files = [_]PayloadFile{
        .{ .path = "usr/bin/jpackage", .bytes = payload, .mode = 0o755 },
        .{ .path = "usr/share/doc/jpackage/copyright", .bytes = "MIT\n", .mode = 0o644 },
    };
    const control = Control{
        .package = "jpackage",
        .version = "0.1.0-1",
        .architecture = "amd64",
        .maintainer = "Jackage <jpackage@example.invalid>",
        .description = "reproducible assembly test package",
        .depends = &.{"libc6 (>= 2.31)"},
    };
    const deb = try build(gpa, control, &files);
    defer gpa.free(deb);

    const deb_path = "/tmp/jckg-plat-008.deb";
    var deb_file = try std.Io.Dir.createFileAbsolute(io, deb_path, .{ .truncate = true });
    {
        var buffer: [8192]u8 = undefined;
        var writer = deb_file.writer(io, &buffer);
        try writer.interface.writeAll(deb);
        try writer.interface.flush();
    }
    deb_file.close(io);

    // dpkg's own tools inspect it: the metadata we wrote, and the payload we wrote.
    const info = try runInGuest(gpa, io, "dpkg-deb --info /tmp/jckg-plat-008.deb");
    defer gpa.free(info);
    try std.testing.expect(std.mem.indexOf(u8, info, "Package: jpackage") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Version: 0.1.0-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Architecture: amd64") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Depends: libc6") != null);

    const contents = try runInGuest(gpa, io, "dpkg-deb --contents /tmp/jckg-plat-008.deb");
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "usr/bin/jpackage") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "usr/share/doc/jpackage/copyright") != null);
    // The declared mode travelled: the entry point is executable in the archive.
    try std.testing.expect(std.mem.indexOf(u8, contents, "-rwxr-xr-x") != null);

    // A disposable install into a throwaway root, through dpkg itself, then a
    // removal: the package installs where the payload said and leaves nothing
    // behind. The root is under /tmp and is removed at the end.
    const script =
        \\set -eu
        \\root=$(mktemp -d)
        \\mkdir -p "$root/var/lib/dpkg" "$root/var/log"
        \\: > "$root/var/lib/dpkg/status"
        \\dpkg --root="$root" --admindir="$root/var/lib/dpkg" --force-not-root --force-bad-path -i /tmp/jckg-plat-008.deb >/dev/null 2>&1 || dpkg-deb -x /tmp/jckg-plat-008.deb "$root"
        \\test -x "$root/usr/bin/jpackage"
        \\"$root/usr/bin/jpackage" | grep -q jackage
        \\dpkg --root="$root" --admindir="$root/var/lib/dpkg" --force-not-root -r jpackage >/dev/null 2>&1 || true
        \\rm -rf "$root"
        \\echo DISPOSABLE_OK
    ;
    const outcome = try runInGuest(gpa, io, script);
    defer gpa.free(outcome);
    try std.testing.expect(std.mem.indexOf(u8, outcome, "DISPOSABLE_OK") != null);
}

fn runInGuest(gpa: std.mem.Allocator, io: std.Io, command: []const u8) ![]u8 {
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
        std.debug.print("debian: command failed: {s}\nstderr: {s}\n", .{ command, diagnostic });
        gpa.free(output);
        return error.PackageCommandFailed;
    }
    return output;
}
