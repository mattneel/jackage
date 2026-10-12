//! Creating and inspecting a disposable ext4 image (M15, IMAGE-005).
//!
//! A root filesystem can be a directory, and a machine that boots needs a filesystem.
//! The export step produces the tree; this step puts it into an ext4 image and then
//! *reads the image back* to check that what landed is what the payload contract
//! declared. Reading it back is the point: a file copied into a tree is not evidence
//! that the filesystem carries it, and a filesystem is where a mode bit or a whole
//! file most often goes missing.
//!
//! Inspection is done with `debugfs` rather than by mounting, because inspection
//! should not require privileges and a test that needs root to look at bytes will be
//! skipped on the machine where it matters. A loopback mount is attempted as well
//! where the environment permits it, and the attempt is reported rather than assumed.
//!
//! This is a Linux module in the same sense the case is: the tools it drives are part
//! of the declared execution environment, and it is evidence of that environment
//! doing the work.
const std = @import("std");
const store_module = @import("../core/store.zig");
const rootfs = @import("rootfs.zig");
const digest = @import("../core/digest.zig");

pub const Error = error{
    ToolMissing,
    ToolFailed,
    InvalidContract,
    ContentMismatch,
    ModeMismatch,
    MissingFile,
    OutOfMemory,
};

/// What the payload contract declares about one file.
pub const Entry = struct {
    path: []const u8,
    digest: []const u8,
    executable: bool = false,
};

pub const Contract = struct {
    entries: []const Entry,

    pub fn find(self: Contract, path: []const u8) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }
};

pub const RunOutput = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: RunOutput, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Runs a command in the guest, capturing both streams.
pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) Error!RunOutput {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.ToolMissing;
    defer child.kill(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
    const stdout = stdout_reader.interface.allocRemaining(gpa, .limited(1 << 20)) catch
        return error.ToolFailed;
    errdefer gpa.free(stdout);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_buffer);
    const stderr = stderr_reader.interface.allocRemaining(gpa, .limited(1 << 20)) catch
        return error.ToolFailed;
    errdefer gpa.free(stderr);

    const term = child.wait(io) catch return error.ToolFailed;
    const code: u8 = switch (term) {
        .exited => |value| value,
        else => return error.ToolFailed,
    };
    return .{ .exit_code = code, .stdout = stdout, .stderr = stderr };
}

pub const Image = struct {
    path: []u8,
    bytes_written: u64,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
    }
};

/// Creates a disposable ext4 image populated from `source_path`.
///
/// `mkfs.ext4 -d` copies a directory into a fresh filesystem, which is why this needs
/// no loop device and no privileges: the image is a file, and it is filled at
/// creation time.
pub fn create(
    gpa: std.mem.Allocator,
    io: std.Io,
    destination: []const u8,
    source_path: []const u8,
    size_mib: u32,
    label: []const u8,
) Error!Image {
    if (size_mib == 0) return error.InvalidContract;
    // A sparse file: `truncate` allocates nothing, and ext4 writes only what it needs.
    // The size is generous on purpose - an image too small for its payload fails
    // inside mkfs where the reason is less clear.
    const sparse = try std.fmt.allocPrint(gpa, "{d}M", .{size_mib});
    defer gpa.free(sparse);
    const truncate_output = try run(gpa, io, &.{ "truncate", "-s", sparse, destination });
    defer truncate_output.deinit(gpa);
    if (truncate_output.exit_code != 0) return error.ToolFailed;

    const mkfs_output = try run(gpa, io, &.{
        "mkfs.ext4",
        "-q",
        "-F",
        "-L",
        label,
        "-d",
        source_path,
        destination,
    });
    defer mkfs_output.deinit(gpa);
    if (mkfs_output.exit_code != 0) return error.ToolFailed;

    const stat_output = try run(gpa, io, &.{ "stat", "-c", "%s", destination });
    defer stat_output.deinit(gpa);
    if (stat_output.exit_code != 0) return error.ToolFailed;
    const size = std.fmt.parseInt(u64, std.mem.trim(u8, stat_output.stdout, " \n"), 10) catch
        return error.ToolFailed;
    return .{ .path = try gpa.dupe(u8, destination), .bytes_written = size };
}

/// Inspects one file inside an image with `debugfs`, without mounting it.
///
/// The commands are the classic ones a filesystem person would type by hand: `stat`
/// for metadata, `dump` for contents. `dump` writes the extracted bytes to a path on
/// the host, which is then compared with the declared digest - so the check is on the
/// bytes the filesystem actually carries.
pub fn inspect(
    gpa: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    entry: Entry,
    store: store_module.Store,
    work_path: []const u8,
) Error!void {
    const expected = digest.Digest.parse(entry.digest) catch return error.InvalidContract;
    if (!store.hasBlob(expected)) return error.InvalidContract;

    const within = try std.fmt.allocPrint(gpa, "/{s}", .{entry.path});
    defer gpa.free(within);

    const dump_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ work_path, std.fs.path.basename(entry.path) });
    defer gpa.free(dump_path);

    const dump_command = try std.fmt.allocPrint(gpa, "dump {s} {s}", .{ within, dump_path });
    defer gpa.free(dump_command);
    const dumped = try run(gpa, io, &.{ "debugfs", "-R", dump_command, image_path });
    defer dumped.deinit(gpa);
    if (dumped.exit_code != 0) return error.MissingFile;

    const extracted = std.Io.Dir.cwd().readFileAlloc(io, dump_path, gpa, .limited(64 * 1024 * 1024)) catch
        return error.MissingFile;
    defer gpa.free(extracted);
    // The bytes the filesystem carries must be the bytes the contract declared. This
    // is the check the case is for: a file copied into a tree is not evidence that the
    // filesystem holds it.
    var found: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(extracted, &found, .{});
    if (!std.mem.eql(u8, &found, &expected.bytes)) return error.ContentMismatch;

    const stat_command = try std.fmt.allocPrint(gpa, "stat {s}", .{within});
    defer gpa.free(stat_command);
    const stat = try run(gpa, io, &.{ "debugfs", "-R", stat_command, image_path });
    defer stat.deinit(gpa);
    if (stat.exit_code != 0) return error.MissingFile;
    // The mode is read from the output rather than assumed: an export that lost the
    // executable bit produces an image that cannot start anything.
    var mode: ?u32 = null;
    var lines = std.mem.splitScalar(u8, stat.stdout, '\n');
    while (lines.next()) |line| {
        // `debugfs stat` prints `Inode: 13   Type: regular   Mode:  0755   Flags: ...`,
        // so the field is found where it appears rather than at the start of the line.
        const at = std.mem.indexOf(u8, line, "Mode:") orelse continue;
        const text = std.mem.trim(u8, line[at + "Mode:".len ..], " \t");
        // The value ends at the next run of spaces; the flags field follows it.
        const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
        mode = std.fmt.parseInt(u32, text[0..end], 8) catch null;
        break;
    }
    const found_mode = mode orelse return error.InvalidContract;
    // The contract declares the owner-execute bit exactly, in both directions: a
    // declared executable that lost its bit cannot run, and a declared plain file that
    // gained one is not the payload that was declared either.
    const is_executable = (found_mode & 0o100) != 0;
    if (entry.executable != is_executable) return error.ModeMismatch;
}

/// Mounts the image, reads the file through the mounted filesystem, and unmounts.
///
/// This is the half of the case that inspection cannot cover: `debugfs` reads the
/// bytes ext4 stored, while a mount asks the kernel to interpret the filesystem, and
/// an image that passes one and fails the other is an image something will not boot.
/// The mount needs privileges, so it goes through sudo; the environment is the
/// declared one and the evidence says whether it permitted the step.
pub fn mountAndRead(
    gpa: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    mount_path: []const u8,
    entry: Entry,
    store: store_module.Store,
) Error!void {
    const expected = digest.Digest.parse(entry.digest) catch return error.InvalidContract;
    if (!store.hasBlob(expected)) return error.InvalidContract;

    std.Io.Dir.cwd().createDirPath(io, mount_path) catch return error.ToolFailed;

    const mounted = try run(gpa, io, &.{ "sudo", "-n", "mount", "-o", "loop,ro", image_path, mount_path });
    defer mounted.deinit(gpa);
    if (mounted.exit_code != 0) return error.ToolFailed;
    // Unmounting is not optional: a leaked mount is a leaked loop device, and a test
    // that leaves one behind poisons the machine it ran on.
    var unmounted = false;
    defer {
        if (!unmounted) {
            const cleanup = run(gpa, io, &.{ "sudo", "-n", "umount", mount_path }) catch null;
            if (cleanup) |output| output.deinit(gpa);
        }
    }

    const through_mount = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ mount_path, entry.path });
    defer gpa.free(through_mount);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, through_mount, gpa, .limited(64 * 1024 * 1024)) catch
        return error.MissingFile;
    defer gpa.free(bytes);
    var found: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &found, .{});
    if (!std.mem.eql(u8, &found, &expected.bytes)) return error.ContentMismatch;

    const status = try run(gpa, io, &.{ "sudo", "-n", "umount", mount_path });
    defer status.deinit(gpa);
    if (status.exit_code != 0) return error.ToolFailed;
    unmounted = true;
}

test "m15/IMAGE-005 validate ext4 image: contents and metadata satisfy the declared payload contract" {
    // The case's platform is Linux and its evidence is recorded there; on any other
    // host the test is skipped rather than failed, so the host suite still passes.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    std.debug.print("JCKG_EVIDENCE IMAGE-005\n", .{});
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    const store_path = "zig-out/jckg-image-005-store";
    const root_path = "zig-out/jckg-image-005-root";
    const image_path = "zig-out/jckg-image-005.ext4";
    const mount_path = "zig-out/jckg-image-005-mnt";
    const work_path = "zig-out/jckg-image-005-work";
    for ([_][]const u8{ store_path, root_path, mount_path, work_path }) |path| cwd.deleteTree(io, path) catch {};
    cwd.deleteFile(io, image_path) catch {};
    defer for ([_][]const u8{ store_path, root_path, mount_path, work_path }) |path| cwd.deleteTree(io, path) catch {};
    defer cwd.deleteFile(io, image_path) catch {};

    var store_root = try cwd.createDirPathOpen(io, store_path, .{});
    defer store_root.close(io);
    const store = store_module.Store.init(io, gpa, store_root);
    try store.ensureLayout();

    // A payload with an executable and a plain file, so the mode check has both
    // answers to give.
    const program = "#!/bin/sh\necho ext4-payload-ok\n";
    const data = "payload data\n";
    const program_digest = try store.importBytes(program, null);
    const data_digest = try store.importBytes(data, null);
    var program_buffer: [digest.Digest.text_length]u8 = undefined;
    var data_buffer: [digest.Digest.text_length]u8 = undefined;
    const program_text = try gpa.dupe(u8, program_digest.text(&program_buffer));
    defer gpa.free(program_text);
    const data_text = try gpa.dupe(u8, data_digest.text(&data_buffer));
    defer gpa.free(data_text);

    const objects = [_]rootfs.Object{
        .{ .path = "bin/jckg", .digest = program_text, .executable = true },
        .{ .path = "share/jckg/data", .digest = data_text },
    };
    const manifest = rootfs.Manifest{ .name = "jckg-ext4", .entry_point = "bin/jckg", .objects = &objects };

    var root = try cwd.createDirPathOpen(io, root_path, .{ .open_options = .{ .iterate = true } });
    defer root.close(io);
    const exported = try rootfs.exportRootfs(gpa, io, store, root, manifest);
    defer exported.deinit(gpa);

    // The rootfs becomes a filesystem.
    try cwd.createDirPath(io, work_path);
    const image = try create(gpa, io, image_path, root_path, 32, "jckg-payload");
    defer image.deinit(gpa);
    try std.testing.expect(image.bytes_written == 32 * 1024 * 1024);

    const contract = Contract{ .entries = &.{
        .{ .path = "bin/jckg", .digest = program_text, .executable = true },
        .{ .path = "share/jckg/data", .digest = data_text },
    } };

    // Inspection: the bytes the filesystem carries, and the mode it recorded.
    for (contract.entries) |entry| try inspect(gpa, io, image_path, entry, store, work_path);

    // Mount: the kernel's interpretation of the same image, read through the mount
    // point and unmounted again.
    for (contract.entries) |entry| try mountAndRead(gpa, io, image_path, mount_path, entry, store);

    // A contract entry the image does not contain is reported as missing rather than
    // as a mismatch: those are different problems.
    const absent = Entry{ .path = "bin/absent", .digest = program_text, .executable = true };
    try std.testing.expectError(error.MissingFile, inspect(gpa, io, image_path, absent, store, work_path));

    // A declared digest that does not match what the filesystem carries is caught by
    // the digest, which is what makes the inspection worth doing.
    const wrong_digest = Entry{ .path = "share/jckg/data", .digest = program_text };
    try std.testing.expectError(error.ContentMismatch, inspect(gpa, io, image_path, wrong_digest, store, work_path));

    // An executable declared non-executable is a mode mismatch: the contract says
    // what the mode must be, and the filesystem is asked rather than trusted.
    const wrong_mode = Entry{ .path = "bin/jckg", .digest = program_text, .executable = false };
    try std.testing.expectError(error.ModeMismatch, inspect(gpa, io, image_path, wrong_mode, store, work_path));

    // The mount point is empty again, which is how the test knows it cleaned up.
    var mounted_dir = try cwd.openDir(io, mount_path, .{ .iterate = true });
    defer mounted_dir.close(io);
    var iterator = mounted_dir.iterate();
    try std.testing.expect(iterator.next(io) catch null == null);
}
